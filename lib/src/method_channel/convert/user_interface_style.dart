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

import '../../types/types.dart';
import '../method_channel.dart';

/// [UserInterfaceStyle] convert extension.
/// @nodoc
extension ConvertUserInterfaceStyle on UserInterfaceStyle {
  /// Converts [UserInterfaceStyle] to [UserInterfaceStyleDto]
  UserInterfaceStyleDto? toDto() {
    switch (this) {
      case UserInterfaceStyle.unspecified:
        return UserInterfaceStyleDto.unspecified;
      case UserInterfaceStyle.light:
        return UserInterfaceStyleDto.light;
      case UserInterfaceStyle.dark:
        return UserInterfaceStyleDto.dark;
    }
  }
}

/// [UserInterfaceStyleDto] convert extension.
/// @nodoc
extension ConvertUserInterfaceStyleDto on UserInterfaceStyleDto? {
  /// Converts [UserInterfaceStyleDto] to [UserInterfaceStyle]
  UserInterfaceStyle? toUserInterfaceStyle() {
    if (this == null) {
      return null;
    }
    switch (this!) {
      case UserInterfaceStyleDto.unspecified:
        return UserInterfaceStyle.unspecified;
      case UserInterfaceStyleDto.light:
        return UserInterfaceStyle.light;
      case UserInterfaceStyleDto.dark:
        return UserInterfaceStyle.dark;
    }
  }
}
