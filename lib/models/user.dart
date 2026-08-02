class User {
  const User({
    required this.id,
    required this.email,
    required this.fullName,
    required this.isActive,
    required this.isSuperuser,
  });

  final String id;
  final String email;
  final String fullName;
  final bool isActive;
  final bool isSuperuser;

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as String,
    email: json['email'] as String,
    fullName: json['full_name'] as String,
    isActive: json['is_active'] as bool? ?? true,
    isSuperuser: json['is_superuser'] as bool? ?? false,
  );
}
