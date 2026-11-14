/// Data for the Profile tab, Walk With Me and "How was it?" feedback.
library;

import 'device_identity.dart' show PeerKey;

/// Strength chips a person can pick for their profile (server slugs → labels).
const profileStrengths = <String, String>{
  'knows_the_area': 'Knows the area',
  'first_aid_trained': 'First-aid trained',
  'walks_this_route_daily': 'Walks this route daily',
  'speaks_kannada': 'Speaks Kannada',
  'speaks_hindi': 'Speaks Hindi',
  'self_defence_trained': 'Self-defence trained',
  'calm_in_a_crisis': 'Calm in a crisis',
  'campus_volunteer': 'Campus volunteer',
};

const profileLanguages = [
  'Kannada',
  'English',
  'Hindi',
  'Tamil',
  'Telugu',
  'Malayalam',
  'Urdu',
  'Marathi',
];

const profileGenders = <String, String>{
  'woman': 'Woman',
  'man': 'Man',
  'non_binary': 'Non-binary',
};

/// Feedback chips (server slugs → labels).
const feedbackChips = <String, String>{
  'well_lit': 'Well lit',
  'busy_street': 'Busy street',
  'felt_uneasy': 'Felt uneasy',
  'poor_footpath': 'Poor footpath',
  'route_confusing': 'Route confusing',
  'companion_was_late': 'Companion was late',
  'would_walk_again': 'Would walk again',
};

class Profile {
  const Profile({
    required this.firstName,
    this.bio = '',
    this.strengths = const [],
    this.languages = const [],
    this.gender,
    this.willingCompanion = false,
  });

  final String firstName;
  final String bio;
  final List<String> strengths;
  final List<String> languages;
  final String? gender;
  final bool willingCompanion;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    firstName: json['first_name'] as String? ?? '',
    bio: json['bio'] as String? ?? '',
    strengths: (json['strengths'] as List? ?? const []).cast<String>(),
    languages: (json['languages'] as List? ?? const []).cast<String>(),
    gender: json['gender'] as String?,
    willingCompanion: json['willing_companion'] as bool? ?? false,
  );

  Map<String, Object?> toJson() => {
    'first_name': firstName,
    'bio': bio,
    'strengths': strengths,
    'languages': languages,
    'gender': gender,
    'willing_companion': willingCompanion,
  };
}

/// What a walk partner sees: no gender, no account details.
class PartnerProfile {
  const PartnerProfile({
    required this.firstName,
    this.bio = '',
    this.strengths = const [],
    this.languages = const [],
  });

  final String firstName;
  final String bio;
  final List<String> strengths;
  final List<String> languages;

  factory PartnerProfile.fromJson(Map<String, dynamic> json) => PartnerProfile(
    firstName: json['first_name'] as String? ?? '',
    bio: json['bio'] as String? ?? '',
    strengths: (json['strengths'] as List? ?? const []).cast<String>(),
    languages: (json['languages'] as List? ?? const []).cast<String>(),
  );
}

class CompanionMe {
  const CompanionMe({
    required this.status,
    this.identityVerified = false,
    this.verifiedMethod,
    this.verifiedAt,
    this.available = false,
  });

  /// none | approved (joined; no approval step) | revoked
  final String status;

  /// Verified, adult, unexpired identity (ID + selfie).
  final bool identityVerified;

  /// 'identity' once joined after identity verification.
  final String? verifiedMethod;
  final DateTime? verifiedAt;
  final bool available;

  /// Joined and can be found by travellers (needs a verified identity).
  bool get approved => status == 'approved' && identityVerified;

  factory CompanionMe.fromJson(Map<String, dynamic> json) => CompanionMe(
    status: json['status'] as String? ?? 'none',
    identityVerified: json['identity_verified'] as bool? ?? false,
    verifiedMethod: json['verified_method'] as String?,
    verifiedAt: DateTime.tryParse(json['verified_at'] as String? ?? '')
        ?.toLocal(),
    available: json['available'] as bool? ?? false,
  );
}

class CompanionCard {
  const CompanionCard({
    required this.companionId,
    required this.profile,
    required this.distanceMeters,
    required this.walkMinutes,
    this.rating,
    this.ratingCount = 0,
  });

  final String companionId;
  final PartnerProfile profile;
  final double? rating;
  final int ratingCount;
  final int distanceMeters;
  final int walkMinutes;

  factory CompanionCard.fromJson(Map<String, dynamic> json) => CompanionCard(
    companionId: json['companion_id'] as String,
    profile: PartnerProfile.fromJson(
      (json['profile'] as Map).cast<String, dynamic>(),
    ),
    rating: (json['rating'] as num?)?.toDouble(),
    ratingCount: json['rating_count'] as int? ?? 0,
    distanceMeters: json['distance_m'] as int? ?? 0,
    walkMinutes: json['walk_minutes'] as int? ?? 1,
  );
}

class RoughArea {
  const RoughArea(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  static RoughArea? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return RoughArea(
      (raw['latitude'] as num).toDouble(),
      (raw['longitude'] as num).toDouble(),
    );
  }
}

/// A request waiting for me as a companion: first name and rough area only.
class WalkRequestView {
  const WalkRequestView({
    required this.id,
    required this.travellerFirstName,
    required this.expiresAt,
    this.roughArea,
    this.distanceMeters,
  });

  final String id;
  final String travellerFirstName;
  final RoughArea? roughArea;
  final int? distanceMeters;
  final DateTime expiresAt;

  factory WalkRequestView.fromJson(Map<String, dynamic> json) =>
      WalkRequestView(
        id: json['id'] as String,
        travellerFirstName: json['traveller_first_name'] as String? ?? '',
        roughArea: RoughArea.fromJson(json['rough_area']),
        distanceMeters: json['distance_m'] as int?,
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
      );
}

class WalkView {
  const WalkView({
    required this.id,
    required this.role,
    required this.status,
    required this.expiresAt,
    this.journeyId,
    this.partner,
    this.handshakeCode,
    this.meetNear,
    this.partnerKeys = const [],
    this.endReason,
  });

  /// Also the live-location session id while accepted.
  final String id;

  /// traveller | companion
  final String role;

  /// requested | accepted | declined | expired | cancelled | ended
  final String status;
  final String? journeyId;
  final PartnerProfile? partner;
  final String? handshakeCode;
  final RoughArea? meetNear;
  final List<PeerKey> partnerKeys;
  final DateTime expiresAt;
  final String? endReason;

  bool get isTraveller => role == 'traveller';
  bool get accepted => status == 'accepted';
  bool get open => status == 'requested' || status == 'accepted';

  factory WalkView.fromJson(Map<String, dynamic> json) => WalkView(
    id: json['id'] as String,
    role: json['role'] as String,
    status: json['status'] as String,
    journeyId: json['journey_id'] as String?,
    partner: json['partner'] is Map
        ? PartnerProfile.fromJson((json['partner'] as Map).cast())
        : null,
    handshakeCode: json['handshake_code'] as String?,
    meetNear: RoughArea.fromJson(json['meet_near']),
    partnerKeys: PeerKey.listFrom(json['partner_keys']),
    expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
    endReason: json['end_reason'] as String?,
  );
}

class FeedbackDraft {
  const FeedbackDraft({
    required this.journeyId,
    required this.routeStars,
    this.walkId,
    this.companionStars,
    this.chips = const [],
    this.note = '',
  });

  final String journeyId;
  final String? walkId;
  final int routeStars;
  final int? companionStars;
  final List<String> chips;
  final String note;

  Map<String, Object?> toJson() => {
    'journey_id': journeyId,
    if (walkId != null) 'walk_id': walkId,
    'route_stars': routeStars,
    if (companionStars != null) 'companion_stars': companionStars,
    'chips': chips,
    'note': note,
  };
}
