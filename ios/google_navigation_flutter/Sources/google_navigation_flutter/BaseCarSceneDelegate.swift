// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CarPlay
import CoreLocation
import Foundation
import GoogleMaps
import GoogleNavigation

open class BaseCarSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPMapTemplateDelegate, GMSNavigatorListener
{
  /// Map options to use for CarPlay views.
  /// Can be set before the CarPlay scene is created to customize map appearance.
  public static var mapOptions: AutoMapViewOptions?

  /// Provides the map options to use when creating the CarPlay map view.
  ///
  /// Override this method in your BaseCarSceneDelegate subclass to provide custom map options
  /// from the native layer. This is useful when you want to set map configuration (like mapId)
  /// directly in native code instead of from Flutter, especially when the CarPlay screen
  /// may already be open.
  ///
  /// The default implementation returns the value from the static property, which can be set
  /// from Flutter via GoogleMapsAutoViewController.setAutoMapOptions().
  ///
  /// - Returns: AutoMapViewOptions containing map configuration, or nil to use defaults
  open func getAutoMapOptions() -> AutoMapViewOptions? {
    BaseCarSceneDelegate.mapOptions
  }

  private var interfaceController: CPInterfaceController?
  private var carWindow: CPWindow?
  private var mapTemplate: CPMapTemplate?
  private var navView: GoogleMapsNavigationView?
  private var navViewController: UIViewController?
  private var templateApplicationScene: CPTemplateApplicationScene?
  private var autoViewEventApi: AutoViewEventApi?
  private var viewRegistry: GoogleMapsNavigationViewRegistry?

  // Gesture tracking - store previous values to compute deltas
  // (gesture recognizers give cumulative values, not deltas)
  private var previousZoomScale: CGFloat = 1.0
  private var previousRotation: CGFloat = 0.0
  private var lastZoomGestureTime: Date = Date.distantPast
  private var lastRotateGestureTime: Date = Date.distantPast
  private var isNavigatorListenerAdded = false

  deinit {
    removeNavigatorListenerIfNeeded()
  }

  public func getNavView() -> GoogleMapsNavigationView? {
    navView
  }

  /// Get the underlying GMSMapView from the navigation view.
  /// Useful for instrument cluster or other contexts that need the typed map view.
  public func getMapView() -> GMSMapView? {
    navView?.getMapView()
  }

  /// Called early in the scene lifecycle, before CarPlay template connection.
  /// Subclasses can override to capture the scene as soon as it connects.
  open func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Default implementation does nothing.
  }

  open func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    self.interfaceController = interfaceController
    carWindow = window
    mapTemplate = getTemplate()
    self.templateApplicationScene = templateApplicationScene
    mapTemplate?.mapDelegate = self
    createVC()
  }

  open func getTemplate() -> CPMapTemplate {
    let template = CPMapTemplate()
    template.showPanningInterface(animated: true)
    return template
  }

  /// Rebuilds and applies the current CarPlay map template.
  public func refreshTemplate(animated: Bool = true) {
    mapTemplate = getTemplate()
    mapTemplate?.mapDelegate = self
    guard let mapTemplate else { return }
    interfaceController?.setRootTemplate(mapTemplate, animated: animated) { _, _ in }
  }

  open func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    removeNavigatorListenerIfNeeded()
    self.interfaceController = nil
    carWindow?.rootViewController = nil
    carWindow = nil
    mapTemplate = nil
    navView?.unregisterView()
    navView = nil
    navViewController = nil
    self.templateApplicationScene = nil
    onNavigationReady(ready: false)
  }

  open func sceneDidBecomeActive(_ scene: UIScene) {}

  /// Called when the CarPlay system suggested content style for this scene has changed (iOS 15.4+)
  @available(iOS 15.4, *)
  @objc open func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    // Subclasses can override this to handle appearance changes.
  }

  func createVC() {
    guard
      let templateApplicationScene,
      navView == nil
    else { return }

    GoogleMapsNavigationPlugin
      .pluginInitializedCallback = { [weak self] viewRegistry, autoViewEventApi, imageRegistry in
        guard let self else { return }
        self.viewRegistry = viewRegistry
        self.autoViewEventApi = autoViewEventApi

        // Get map options from overridable method (can be customized in subclasses)
        let autoMapOptions = self.getAutoMapOptions()

        // Fall back to CarPlay content style / user location when options are not provided.
        let contentStyle = templateApplicationScene.contentStyle
        let resolvedForceNightMode: GMSNavigationLightingMode? =
          autoMapOptions?.forceNightMode
          ?? (contentStyle == .dark
            ? .lowLight : contentStyle == .light ? .normal : nil)
        let resolvedMapColorScheme = autoMapOptions?.mapColorScheme ?? contentStyle
        let resolvedCameraPosition: GMSCameraPosition? = {
          if let cameraPosition = autoMapOptions?.cameraPosition {
            return cameraPosition
          }
          if let location = CLLocationManager().location {
            return GMSCameraPosition.camera(
              withLatitude: location.coordinate.latitude,
              longitude: location.coordinate.longitude,
              zoom: 16.0
            )
          }
          return nil
        }()

        self.navView = GoogleMapsNavigationView(
          frame: templateApplicationScene.carWindow.screen.bounds,
          viewIdentifier: nil,
          isNavigationView: true,
          viewRegistry: viewRegistry,
          viewEventApi: nil,
          navigationUIEnabledPreference:
            autoMapOptions?.navigationUIEnabledPreference ?? .automatic,
          forceNightMode: resolvedForceNightMode,
          navigationHeaderStylingOptions: nil,
          mapConfiguration: MapConfiguration(
            cameraPosition: resolvedCameraPosition,
            mapType: autoMapOptions?.mapType ?? .normal,
            compassEnabled: false,
            rotateGesturesEnabled: false,
            scrollGesturesEnabled: true,
            tiltGesturesEnabled: false,
            zoomGesturesEnabled: true,
            scrollGesturesEnabledDuringRotateOrZoom: false,
            cameraTargetBounds: nil,
            minZoomPreference: nil,
            maxZoomPreference: nil,
            padding: nil,
            mapId: autoMapOptions?.mapId,
            mapColorScheme: resolvedMapColorScheme
          ),
          imageRegistry: imageRegistry,
          isCarPlayView: true,
          screen: templateApplicationScene.carWindow.screen
        )

        // Set up prompt visibility callback to allow override
        self.navView?.promptVisibilityCallback = { [weak self] promptVisible in
          self?.onPromptVisibilityChanged(promptVisible: promptVisible)
        }

        self.navView?.indoorFocusedBuildingChangedCallback = { [weak self] building in
          self?.sendIndoorFocusedBuildingChangedEvent(building: building)
        }

        self.navView?.indoorActiveLevelChangedCallback = { [weak self] building in
          self?.sendIndoorActiveLevelChangedEvent(building: building)
        }

        // Set up custom event callback from Flutter to allow override
        self.navView?.customNavigationAutoEventFromFlutterCallback = { [weak self] event, data in
          self?.onCustomNavigationAutoEventFromFlutter(event: event, data: data)
        }

        // Set up navigation UI enabled callback to allow override
        self.navView?.navigationUIEnabledChangedCallback = { [weak self] isEnabled in
          self?.onNavigationUIEnabledChanged(isEnabled: isEnabled)
        }

        // Set up session attachment callback to allow override
        self.navView?.sessionAttachmentChangedCallback = { [weak self] isAttachedToSession in
          self?.onSessionAttachmentChanged(isAttachedToSession: isAttachedToSession)
        }

        try? self.navView?.setMyLocationEnabled(true)
        self.navView?.setNavigationHeaderEnabled(false)
        self.navView?.setRecenterButtonEnabled(false)
        self.navView?.setNavigationFooterEnabled(false)
        self.navView?.setSpeedometerEnabled(false)
        self.navView?.setReportIncidentButtonEnabled(false)
        try? self.navView?.setMyLocationButtonEnabled(false)
        // Indoor level picker is not user-operable on CarPlay,
        // so keep it disabled by default for car surfaces.
        self.navView?.setIndoorLevelPickerEnabled(false)
        self.navViewController = UIViewController()
        self.navViewController?.view = self.navView?.view()
        self.carWindow?.rootViewController = self.navViewController
        self.interfaceController?.setRootTemplate(self.mapTemplate!, animated: true) {
          [weak self] _, error in
          guard let self else { return }
          if error != nil {
            self.onNavigationReady(ready: false)
          } else {
            // Re-apply UI hiding settings after template is set (they may get reset).
            try? self.navView?.setMyLocationButtonEnabled(false)
            self.navView?.setRecenterButtonEnabled(false)
            self.navView?.setNavigationHeaderEnabled(false)
            self.navView?.setNavigationFooterEnabled(false)
            self.onNavigationReady(ready: true)
          }
        }

        self.viewRegistry?.onHasCarPlayViewChanged = { isAvalable in
          self.sendAutoScreenAvailabilityChangedEvent(isAvailable: isAvalable)
        }
      }
  }

  /// Called when the navigation view is ready or becomes unavailable.
  /// Subclasses can override for lifecycle hooks. This does not auto-register a
  /// GMSNavigatorListener — apps that need one should call setupNavigatorListener()
  /// (or register their own listener, as RoadQuest does).
  open func onNavigationReady(ready: Bool) {
    // Intentionally empty: no automatic navigator listener registration.
  }

  /// Opt-in: register this scene delegate as a GMSNavigatorListener.
  /// Prefer removing via disconnect/deinit; call only if the host app does not
  /// already own a navigator listener.
  public func setupNavigatorListener() {
    trySetupNavigatorListener()
  }

  private func trySetupNavigatorListener() {
    guard !isNavigatorListenerAdded else { return }

    do {
      let navigator = try GoogleMapsNavigationSessionManager.shared.getNavigator()
      navigator.add(self)
      isNavigatorListenerAdded = true
    } catch {
      // Session may not be initialized yet; host app can retry later.
    }
  }

  private func removeNavigatorListenerIfNeeded() {
    guard isNavigatorListenerAdded else { return }
    isNavigatorListenerAdded = false
    do {
      let navigator = try GoogleMapsNavigationSessionManager.shared.getNavigator()
      navigator.remove(self)
    } catch {
      // Navigator may already be torn down.
    }
  }

  // MARK: - GMSNavigatorListener

  open func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: NSNotification.Name("GMSNavigatorDidUpdateNavInfo"),
        object: nil,
        userInfo: ["navInfo": navInfo]
      )
    }
  }

  // MARK: - CPMapTemplateDelegate

  open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    panWith direction: CPMapTemplate.PanDirection
  ) {
    stopFollowingCameraForUserPan()
    let scrollAmount = scrollAmount(for: direction)
    if let mapView = navView?.getMapView() {
      mapView.moveCamera(
        GMSCameraUpdate.scrollBy(x: scrollAmount.x, y: scrollAmount.y)
      )
    }
  }

  open func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
    // Leave guidance follow mode so Nav SDK camera updates don't fight the gesture.
    stopFollowingCameraForUserPan()
  }

  open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didUpdatePanGestureWithTranslation translation: CGPoint,
    velocity: CGPoint
  ) {
    // CarPlay reports per-update translation deltas (not cumulative from gesture start).
    // Treating them as cumulative causes back-and-forth flickering.

    // Keep sensitivity mild; vertical scroll feels stronger on tilted nav cameras.
    let screenWidth = carWindow?.screen.bounds.width ?? 800.0
    let baseScaleFactor: CGFloat = 4.0
    let screenAdjustment = max(1.0, screenWidth / 800.0)
    let scaleX = baseScaleFactor * screenAdjustment
    let scaleY = scaleX * 0.45

    // Reverse so the map follows the finger.
    let scrollX = -translation.x * scaleX
    let scrollY = -translation.y * scaleY

    // moveCamera avoids animation-queue overshoot during continuous gestures.
    if let mapView = navView?.getMapView() {
      mapView.moveCamera(GMSCameraUpdate.scrollBy(x: scrollX, y: scrollY))
    }
  }

  open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didEndPanGestureWithVelocity velocity: CGPoint
  ) {
    // Intentionally do not re-enable follow mode; user can press recenter.
  }

  /// Stops nav follow-camera so manual pan is not overridden by guidance updates.
  private func stopFollowingCameraForUserPan() {
    guard let mapView = navView?.getMapView() else { return }
    if mapView.cameraMode == .following {
      mapView.cameraMode = .free
    }
  }

  @available(iOS 26.0, *)
  open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didUpdateZoomGestureWithCenter center: CGPoint,
    scale: CGFloat,
    velocity: CGFloat
  ) {
    let now = Date()
    let timeSinceLastZoom = now.timeIntervalSince(lastZoomGestureTime)
    if timeSinceLastZoom > 0.3 || (abs(scale - 1.0) < abs(previousZoomScale - 1.0) * 0.5) {
      previousZoomScale = 1.0
    }
    lastZoomGestureTime = now

    let deltaScale = scale / previousZoomScale
    previousZoomScale = scale
    if abs(deltaScale - 1.0) < 0.005 {
      return
    }

    let amplifiedZoom = log2(Double(deltaScale)) * 8.0
    if let mapView = navView?.getMapView() {
      let currentCamera = mapView.camera
      let newZoom = max(min(Float(Double(currentCamera.zoom) + amplifiedZoom), 21.0), 1.0)
      let newCamera = GMSCameraPosition.camera(
        withTarget: currentCamera.target,
        zoom: newZoom,
        bearing: currentCamera.bearing,
        viewingAngle: currentCamera.viewingAngle
      )
      mapView.animate(to: newCamera)
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didRotateWithCenter center: CGPoint,
    rotation: CGFloat,
    velocity: CGFloat
  ) {
    let now = Date()
    let timeSinceLastRotate = now.timeIntervalSince(lastRotateGestureTime)
    if timeSinceLastRotate > 0.3 || (abs(rotation) < abs(previousRotation) * 0.5) {
      previousRotation = 0.0
    }
    lastRotateGestureTime = now

    let deltaRotation = rotation - previousRotation
    previousRotation = rotation
    if abs(deltaRotation) < 0.005 {
      return
    }

    let amplifiedRotation = deltaRotation * 180 / .pi * 12.0
    if let mapView = navView?.getMapView() {
      let newBearing = mapView.camera.bearing - Double(amplifiedRotation)
      mapView.animate(toBearing: newBearing)
    }
  }

  @objc open func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    displayStyleFor maneuver: CPManeuver
  ) -> CPManeuverDisplayStyle {
    []
  }

  @available(iOS 17.4, *)
  @objc open func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool {
    false
  }

  func scrollAmount(for direction: CPMapTemplate.PanDirection) -> CGPoint {
    let horizontalScrollDistance: CGFloat = 80.0
    // Vertical pan feels larger on tilted navigation cameras; keep it milder.
    let verticalScrollDistance: CGFloat = 36.0
    var scrollAmount = CGPoint(x: 0.0, y: 0.0)

    if direction.contains(.left) {
      scrollAmount.x = -horizontalScrollDistance
    }
    if direction.contains(.right) {
      scrollAmount.x = horizontalScrollDistance
    }
    if direction.contains(.up) {
      scrollAmount.y = -verticalScrollDistance
    }
    if direction.contains(.down) {
      scrollAmount.y = verticalScrollDistance
    }

    if scrollAmount.x != 0, scrollAmount.y != 0 {
      let factor = CGFloat(Double(1.0 / sqrt(2.0)))
      scrollAmount.x *= factor
      scrollAmount.y *= factor
    }

    return scrollAmount
  }

  /// Checks if a traffic prompt is currently visible on the CarPlay screen.
  open func isPromptVisible() -> Bool {
    return navView?.isPromptVisible() ?? false
  }

  /// Called when traffic prompt visibility changes on the CarPlay screen.
  open func onPromptVisibilityChanged(promptVisible: Bool) {
    autoViewEventApi?.onPromptVisibilityChanged(
      promptVisible: promptVisible,
      completion: { _ in }
    )
  }

  open func sendCustomNavigationAutoEvent(event: String, data: Any) {
    autoViewEventApi?.onCustomNavigationAutoEvent(event: event, data: data) { _ in }
  }

  open func onCustomNavigationAutoEventFromFlutter(event: String, data: Any) {
    // Default implementation does nothing
  }

  open func onNavigationUIEnabledChanged(isEnabled: Bool) {
    autoViewEventApi?.onNavigationUIEnabledChanged(
      navigationUIEnabled: isEnabled,
      completion: { _ in }
    )
  }

  open func onSessionAttachmentChanged(isAttachedToSession: Bool) {
    // Default implementation does nothing
  }

  // MARK: - Public Map Control Methods

  public func zoomIn() {
    handleZoom(zoomIn: true)
  }

  public func zoomOut() {
    handleZoom(zoomIn: false)
  }

  private func handleZoom(zoomIn: Bool) {
    guard let navView = navView else { return }

    let mapView = navView.getMapView()
    let currentCamera = mapView.camera
    let currentZoom = currentCamera.zoom
    let zoomDelta: Float = zoomIn ? 1.0 : -1.0
    let newZoom = max(currentZoom + zoomDelta, 1.0)
    let isGuidanceActive = mapView.navigator?.isGuidanceActive ?? false

    if isGuidanceActive && mapView.cameraMode == .following {
      mapView.followingZoomLevel = newZoom
    } else {
      let newCamera = GMSCameraPosition.camera(
        withTarget: currentCamera.target,
        zoom: newZoom,
        bearing: currentCamera.bearing,
        viewingAngle: currentCamera.viewingAngle
      )
      mapView.animate(to: newCamera)
    }
  }

  /// Re-center camera to follow user location (cockpit mode).
  public func recenter() {
    guard let navView = navView else { return }
    let currentZoom = Double(navView.getMapView().camera.zoom)
    navView.followMyLocation(perspective: .tilted, zoomLevel: currentZoom)
  }

  func sendAutoScreenAvailabilityChangedEvent(isAvailable: Bool) {
    autoViewEventApi?.onAutoScreenAvailabilityChanged(isAvailable: isAvailable) { _ in }
  }

  func sendIndoorFocusedBuildingChangedEvent(building: IndoorBuildingDto?) {
    autoViewEventApi?.onIndoorFocusedBuildingChanged(building: building) { _ in
    }
  }

  func sendIndoorActiveLevelChangedEvent(building: IndoorBuildingDto?) {
    autoViewEventApi?.onIndoorActiveLevelChanged(building: building) { _ in }
  }
}
