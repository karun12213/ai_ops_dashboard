enum WorkspaceRole { owner, member }

class WorkspaceLocation {
  const WorkspaceLocation({
    required this.id,
    required this.name,
    required this.currencyCode,
  });

  final String id;
  final String name;
  final String currencyCode;

  factory WorkspaceLocation.fromJson(Map<String, dynamic> json) {
    return WorkspaceLocation(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      currencyCode: _string(json, 'currency_code'),
    );
  }
}

class WorkspaceAccess {
  const WorkspaceAccess({
    required this.id,
    required this.name,
    required this.role,
    required this.locations,
  });

  final String id;
  final String name;
  final WorkspaceRole role;
  final List<WorkspaceLocation> locations;

  factory WorkspaceAccess.fromJson(Map<String, dynamic> json) {
    final rawLocations = json['locations'];
    if (rawLocations is! List) {
      throw const FormatException('Invalid workspace locations.');
    }
    return WorkspaceAccess(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      role: switch (_string(json, 'role')) {
        'owner' => WorkspaceRole.owner,
        'member' => WorkspaceRole.member,
        _ => throw const FormatException('Invalid workspace role.'),
      },
      locations: rawLocations
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException('Invalid workspace location.');
            }
            return WorkspaceLocation.fromJson(item);
          })
          .toList(growable: false),
    );
  }

  WorkspaceLocation? locationById(String? locationId) {
    if (locationId == null) return null;
    for (final location in locations) {
      if (location.id == locationId) return location;
    }
    return null;
  }
}

class WorkspaceContext {
  const WorkspaceContext({required this.workspaces});

  final List<WorkspaceAccess> workspaces;

  factory WorkspaceContext.fromJson(Map<String, dynamic> json) {
    final rawWorkspaces = json['workspaces'];
    if (rawWorkspaces is! List) {
      throw const FormatException('Invalid workspace context.');
    }
    return WorkspaceContext(
      workspaces: rawWorkspaces
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException('Invalid workspace item.');
            }
            return WorkspaceAccess.fromJson(item);
          })
          .toList(growable: false),
    );
  }
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid workspace $key.');
  }
  return value;
}
