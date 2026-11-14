"""My profile (P1-W3-profile-tab)."""

PRIYA = {
    "first_name": "Priya",
    "bio": "Final-year student, walk home from the library most nights.",
    "strengths": ["knows_the_area", "speaks_kannada", "knows_the_area"],
    "languages": ["Kannada", "English"],
    "gender": "woman",
    "willing_companion": True,
}


def test_no_profile_until_saved_then_round_trip(client, make_user) -> None:
    user = make_user("priya@college.edu")
    resp = client.get("/profile", headers=user["headers"])
    assert resp.status_code == 404 and resp.json()["detail"] == "no_profile"

    saved = client.put("/profile", json=PRIYA, headers=user["headers"])
    assert saved.status_code == 200, saved.text
    assert saved.json()["strengths"] == ["knows_the_area", "speaks_kannada"]  # deduplicated
    assert client.get("/profile", headers=user["headers"]).json() == saved.json()

    edited = client.put(
        "/profile",
        json={**PRIYA, "bio": "", "gender": None, "willing_companion": False},
        headers=user["headers"],
    ).json()
    assert edited["gender"] is None and edited["willing_companion"] is False


def test_profile_validation(client, make_user) -> None:
    user = make_user("v@college.edu")
    for bad in (
        {**PRIYA, "first_name": "  "},
        {**PRIYA, "bio": "x" * 201},
        {**PRIYA, "strengths": ["very_strong"]},
        {**PRIYA, "gender": "robot"},
    ):
        assert client.put("/profile", json=bad, headers=user["headers"]).status_code == 422


def test_profile_needs_sign_in_and_is_private(client, make_user) -> None:
    assert client.get("/profile").status_code == 401
    priya, other = make_user("p@college.edu"), make_user("o@college.edu")
    client.put("/profile", json=PRIYA, headers=priya["headers"])
    # There is no way to read someone else's profile: only your own.
    assert client.get("/profile", headers=other["headers"]).status_code == 404


def test_profile_writes_are_audited_without_personal_data(client, db, make_user) -> None:
    from sqlalchemy import select

    from app.core.audit import AuditEvent

    user = make_user("a@college.edu")
    client.put("/profile", json=PRIYA, headers=user["headers"])
    rows = db.scalars(select(AuditEvent).where(AuditEvent.action == "profile.updated")).all()
    assert len(rows) == 1 and rows[0].target is None
    assert "Priya" not in (rows[0].action + str(rows[0].target))
