# SafeThread: Who Builds What (4-Person Split)

> Read this once and you should know **what you are building, why it matters, and when you are done.**
> Full details live in `SafeThread_HLD_and_TechStack.md`. This doc is the simple version.

---

## The idea in 30 seconds

Most harm to women and children happens on **ordinary walks home**, not on streets anyone has flagged. Safety apps today wait for an SOS, and by then it's too late.

SafeThread does four things:

1. **Avoid**: show safer routes and honest risk labels before you walk
2. **Reduce**: you're never alone (a verified companion walks with you) and never unwatched (check-ins)
3. **Interrupt**: if something goes wrong, family + 112 + nearby verified people are alerted **at the same time**
4. **Fix**: anonymous reports show the campus or city where to fix lights and other problems

**The one rule everyone follows:** this app must never become a tool to track or stalk the people it protects.

---

## The 4 roles at a glance

| Person | Role | Builds | In one line |
|---|---|---|---|
| **P1** | **Mobile App** | Everything the user touches | "The phone is the safety net. It must work even with no internet." |
| **P2** | **Safety Core Backend** | Login, contacts, journeys, alerts, infra | "When something goes wrong, the right people find out, fast." |
| **P3** | **Trust: Verification + Walk With Me** | Who is verified, companion walks, anonymity after | "Strangers are accountable during the walk and strangers again after it." |
| **P4** | **Insight: Reports, Routing, Dashboard** | Anonymous reports, risk labels, safe routes, campus dashboard | "Turn what people sense into fixes, without exposing anyone." |

```
            ┌──────────────── P1: Mobile App ────────────────┐
            │  screens · on-phone timers · SOS · offline SMS │
            └───────┬───────────────┬───────────────┬────────┘
                    │               │               │
         ┌──────────▼─────┐ ┌───────▼────────┐ ┌────▼──────────────┐
         │ P2: Safety Core│ │ P3: Trust      │ │ P4: Insight       │
         │ login·journeys │◄┤ verification   │ │ reports·risk      │
         │ alerts·infra   │ │ walks·anonymity│ │ routing·dashboard │
         └────────────────┘ └────────────────┘ └───────────────────┘
```

---

## P1: Mobile App (Flutter)

### Why this matters
The phone is where safety actually happens. If the internet drops, the battery is at 3%, or our server is down, **the phone alone must still alert family.** A safety app that only works online fails exactly when it's needed.

### What you build
**Screens**
- [ ] Sign up (phone OTP), add trusted contacts
- [ ] Plan a journey: destination, check-in timer, who gets alerted
- [ ] Journey in progress: check-in button, SOS button
- [ ] Walk With Me: request, see companion's photo/name, **handshake code screen**, masked chat
- [ ] Map with safe route + risk labels
- [ ] Submit an anonymous report (place + what's wrong)
- [ ] Companion mode: go on duty, accept a walk, liveness selfie

**Safety logic that runs on the phone**
- [ ] **Journey timers run on the phone**, not just the server
- [ ] **Duress PIN**: looks like a normal "I'm OK" but silently raises the alarm
- [ ] **Covert SOS**: press power button 5×, or shake, without unlocking
- [ ] **Route deviation check** on the phone (nothing sent unless something looks wrong)
- [ ] **SMS fallback**: if no internet, phone texts contacts directly with location
- [ ] **Low-battery mode**: at ≤10%, send last location to contacts and switch to SMS-only

**Privacy on the phone**
- [ ] Live location to contacts is **end-to-end encrypted** (server can't read it)
- [ ] Before a report is uploaded, the phone **blurs the location (~100 m)** and rounds the time ("Tue 8–10 pm")
- [ ] Block screenshots on sensitive screens (companion profile, handshake)
- [ ] Keys stored in the phone's secure hardware (Keystore / Secure Enclave)

### Never break these
- ❌ Never require ID just to be protected
- ❌ Never let a server problem stop an alert
- ❌ Never upload exact report locations

### You need from others
- P2: login, journey, and alert APIs
- P3: walk, verification, and handshake APIs
- P4: routes, risk labels, and report submission APIs

### Done when
✅ Turn off Wi-Fi and data, miss a check-in, and your contact still gets an SMS with your location.

---

## P2: Safety Core Backend

### Why this matters
When a girl misses a check-in or presses SOS, **every second counts.** Family, 112, and nearby helpers must all be alerted **at once**, not one after another, and the system must keep trying until a real person says "I've got it."

### What you build
**Accounts**
- [ ] Phone OTP sign-up + **device-bound login** (stops SIM-swap takeovers)
- [ ] Trusted contacts: add, list, and **remove silently** (for when the contact is the problem, e.g. an abusive partner)

**Journeys**
- [ ] Journey states: planned → active → check-in due → private prompt → contact alert → full alert → resolved
- [ ] User-chosen settings: timers, who to alert, auto-call 112 or not
- [ ] **Watchdog**: if a phone goes silent mid-journey, alert contacts

**Alerts (escalation)**
- [ ] Alert everyone **in parallel**: contacts + 112 + nearby responders (via P3)
- [ ] Try **push → SMS → voice call** until someone acknowledges
- [ ] Same alert triggered twice = only one set of messages (no spam, no confusion)
- [ ] **Signed alerts** so contacts can tell real alerts from fakes

**Live location relay**
- [ ] Forward encrypted location between traveller and contacts, **without reading or storing it**

**Infra (shared foundation)**
- [ ] Repo, CI/CD, cloud setup (Mumbai region), database, Redis, secrets/keys (KMS)
- [ ] Logging that never logs personal data; audit log nobody can edit

### Never break these
- ❌ Never store live location
- ❌ Never let contacts see location outside an active journey or alert
- ❌ Never notify a contact that they were removed

### You need from others
- P1: heartbeat and event calls from the phone
- P3: "find nearby responders" for full alerts

### Done when
✅ SOS reaches contacts by push in seconds. If nobody responds, it automatically moves to SMS, then a call. A duplicate trigger sends nothing extra.

---

## P3: Trust (Verification + Walk With Me + Anonymity)

### Why this matters
Walking beside a stranger is only safe if **the stranger is accountable.** In 2014 an Uber driver in Delhi got through using a **forged police certificate**. So we verify from the source, not from documents people show us.

Once the walk ends, both people must become **strangers again**. The companion should never be able to find her later.

### What you build
**Verification (trust levels)**

| Level | Who | How |
|---|---|---|
| 0 | Everyone | Phone number only. **Protection never needs ID** |
| 1 | Want to be a companion | Aadhaar app / DigiLocker (government-signed) + live selfie matched to ID photo |
| 2 | Campus companion (pilot) | Level 1 + college email/SSO + campus security confirms |
| 3 | City responder (later) | Level 2 + signed police clearance + training + 2 people vouch + probation |

- [ ] Integrate a KYC vendor (Aadhaar app sharing / DigiLocker) and a liveness vendor
- [ ] **Store only the result** (level, first name, photo). Delete ID data right after
- [ ] Block duplicate accounts using a one-way hash of identity details
- [ ] **Fresh selfie check every time** someone accepts a walk (stops account sharing or selling)

**Matching**
- [ ] Find verified companions within ~500 m
- [ ] Companions see only a **rough area**, never her exact location, until she confirms
- [ ] Max alerts per companion per hour (stops anyone using alerts to scout)
- [ ] **Don't pair the same two people again** for 14 days unless she chooses to
- [ ] Filters: women-only, campus-only

**Walk With Me session**
- [ ] Meet at a **public point**, not her location
- [ ] Companion's name + photo also sent to her trusted contact
- [ ] **Handshake code** on both phones must match in person
- [ ] Masked chat: no phone numbers ever exchanged
- [ ] Walk ends at a **random public drop point**, never her door (her contact watches the last stretch)

**After the walk (anonymity)**
- [ ] Companion's app shows only "Completed a walk." No map, no name, no place
- [ ] Chat closes 30 minutes after the walk
- [ ] Her view of the companion expires after 7 days
- [ ] Route data deleted at close (destroy its encryption key)
- [ ] **Sealed record** of who walked with whom: opened only by **2 officers together**, only on complaint or police request, **destroyed after 30 days**

**Trust & Safety tools**
- [ ] Complaint → companion suspended immediately, reviewed after
- [ ] Companion scoring (no-shows, complaints, odd patterns)
- [ ] Internal console for reviews and suspensions

### Never break these
- ❌ Never store Aadhaar numbers or ID images
- ❌ Never show a companion her home, destination, name, or number
- ❌ Never let one person open the sealed record alone

### You need from others
- P1: selfie capture, handshake screen, chat UI
- P2: login, contacts, notifications

### Done when
✅ Red-team test: after a walk, a "companion" tries every way to find the girl again (history, chat, re-matching, drop point) and **fails.**

---

## P4: Insight (Reports + Risk + Routing + Dashboard)

### Why this matters
Women already know which lane is dark and which stop is empty. They quietly avoid them, but **nobody records it.** We turn that hidden knowledge into safer routes today and fixed lights tomorrow, without exposing who reported.

### What you build
**Anonymous reports**
- [ ] Accept reports with **no user ID** (only a "real device" token)
- [ ] Reports are about **places and conditions**, never people. Reject names, phone numbers, vehicle plates
- [ ] Rate-limit each device; one device counts once per problem spot
- [ ] Keep this in a **separate database** from user data (if it leaks, nobody is exposed)

**Clustering**
- [ ] Group reports by area × time of day × type ("back gate, 8–10 pm, no lighting")
- [ ] **Hide a cluster until** it has at least 5 reports from at least 3 different devices
- [ ] Later: NLP to sort report types, with multilingual support

**Risk labels**
- [ ] Only three labels: **"Strong evidence of concern"**, **"Some reports of concern"**, **"Insufficient data"**
- [ ] **Never say "safe."** A quiet street with no reports isn't safe, it's unknown
- [ ] Labels change by time of day

**Safe routing**
- [ ] Set up Valhalla on OpenStreetMap data
- [ ] Route cost = travel time + (user's caution level × risk) + accessibility (stairs, no footpath)
- [ ] Use lighting data, open shops nearby, and published clusters
- [ ] Show the trade-off honestly: "+4 min, avoids a dark 350 m stretch"
- [ ] Don't log who routed from where to where

**Campus dashboard**
- [ ] Map of published clusters for campus security
- [ ] "Mark as fixed" button
- [ ] Before/after view: **did reports drop after the fix?** (our headline impact metric)

### Never break these
- ❌ Never link a report to a user
- ❌ Never show a cluster below the threshold
- ❌ Never label anywhere "safe"

### You need from others
- P1: on-phone location blurring before upload, report screen, map screen
- P2: infra, database, deployment

### Done when
✅ Campus security sees a real cluster ("back gate, no lights, 8–10 pm"), marks it fixed, and the dashboard shows whether reports dropped.

---

## How the pieces connect

| From → To | What passes between them |
|---|---|
| P1 → P2 | Sign-up, contacts, journey events, heartbeats, SOS |
| P1 → P3 | Selfie for verification, walk requests, handshake code, chat |
| P1 → P4 | Blurred reports, route requests |
| P2 → P3 | "Full alert: find nearby responders" |
| P3 → P2 | List of responders to notify |
| P4 → P1 | Routes + risk labels |
| P4 → Dashboard | Published clusters only |

**Week 1 task for everyone:** agree on these APIs together and write them down. That's what lets all four work in parallel.

---

## Timeline (12 weeks, campus pilot)

| Weeks | P1 Mobile | P2 Safety Core | P3 Trust | P4 Insight |
|---|---|---|---|---|
| 1–2 | App shell, sign-up, contacts screens | Repo, CI, cloud, login, contacts | Pick KYC + liveness vendors, sandbox access | Report data model, separate DB |
| 3–4 | Journey screens, on-phone timers, SOS, duress PIN | Journey states, watchdog, alert ladder | Level 1 + Level 2 verification | Report intake + filters + rate limits |
| 5–6 | SMS fallback, low-battery mode, E2E location | Location relay, signed alerts | Matching + rules (radius, caps, no re-pair) | Clustering + threshold + risk labels |
| 7–8 | Walk screens, handshake, chat, selfie | Connect responder alerts | Walk lifecycle, drop points, after-walk wipe, sealed record | Valhalla + safety costing |
| 9–10 | Map + routes + report screen + location blur | Load test alerts, monitoring | Complaints, suspension, T&S console | Campus dashboard + before/after |
| 11 | **Everyone: red-team week.** Try to stalk after a walk, fake a companion, spam reports, spoof an alert | ← | ← | ← |
| 12 | **Pilot launch on one campus** + external security test | ← | ← | ← |

---

## Rules all four of us own

1. **Protection never needs ID.** Only companions get verified.
2. **Never store what we don't need.** No live location, no ID documents, no route after a walk.
3. **The phone must work alone.** No internet ≠ no safety.
4. **Nobody can see anybody outside an active session.** Not contacts, not companions, not admins.
5. **Never say "safe."** Only what the evidence shows.
6. **Reports are about places, never people.**
7. **Every sensitive action is logged** in a log nobody can edit.

---

## Quick glossary

| Term | Meaning |
|---|---|
| **Traveller** | The person making the journey |
| **Trusted contact** | Family or a friend she chose to watch over her |
| **Companion / responder** | Verified person who walks with her or comes to help |
| **Duress PIN** | A second PIN that looks like "I'm OK" but secretly raises the alarm |
| **Handshake code** | 4-digit code shown on both phones; it must match when they meet |
| **Drop point** | Random public place where the companion's walk ends (never her door) |
| **Sealed record (escrow)** | Locked record of who walked with whom; 2 officers needed to open it; deleted after 30 days |
| **Crypto-shredding** | Deleting the encryption key so the data can never be read again |
| **Cluster** | A group of anonymous reports about the same spot and time |
| **k/m threshold** | A cluster stays hidden until it has 5+ reports from 3+ devices |
