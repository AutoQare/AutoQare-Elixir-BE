# Observations and privacy

What AutoQare keeps about the people and companies our team works with,
why, for how long, and how a person is forgotten (AQ-10 §9, QP10-15;
PLAN §10.5). The extension's own note is its `PRIVACY.md`.

## Why we keep it

Our business-development team writes to recruiters, hiring managers and
clients. Knowing when someone is usually around, and how fast they reply,
lets us write at a good time and not chase people who aren't there. That
is a **legitimate interest**: it helps the people we write to as much as
us, it is limited to what a pattern or a reminder needs, and it never
leaves AutoQare.

These people are not our users. So we keep as little as we can, we delete
it on a schedule, and anyone can ask to be forgotten.

## What we keep

An **observation** is one fact about a company or a contact:

| Kind | From |
|---|---|
| A company posted or reposted a job | the jobs our team saves or captures |
| An Upwork client last viewed their job | the job page, when someone on the team captures it |
| A contact replied, and how long after our message | the conversations we log, upload, forward or capture |
| A contact is active on LinkedIn ("Active 2 h ago") | read once, when someone presses *Capture conversation* |
| An Upwork client is online | read while someone on the team has that room open |
| Anything else a person logs by hand | a note of at most 500 characters |

Each row holds the kind, when it was seen, when the person was active,
where it came from, who on our team saw it, and the job or message it is
about. **Never page text**, never a message's words.

Beside them we keep **hour counts**: for each company or contact, how many
observations fell in each hour of the week (`subject_hours`). They are
what the heat map and the "usually online" sentence are built from, and
they hold no timeline.

**Nothing is fetched in the background.** The extension only reads pages a
person on our team already has open, and never clicks, sends or reloads
anything (PLAN §0, §10.5).

## Who sees it

Staff of the teams that work with the company or contact (its jobs, leads
or conversations), and the system admin. Customers never see it. A watch
— "tell me when this person comes online" — is its owner's alone.

## How long

Observations are deleted after the organisation's
`observation_retention_days`, **180 days** unless Settings › System says
otherwise, by a daily sweep (`Core.Workers.ObservationSweep`). The hour
counts stay: that roll-up is the pattern, without a timeline of a person.

## Forgetting someone

A team lead of a team that works with the person, or the system admin,
can press *Forget this person* on a contact:

- their observations, hour counts and watches are deleted at once;
- they are marked **do-not-contact**, so nobody writes to them again;
- one audit row records who did it and when.

*Forget its people* on a company does the same for each of its contacts.
The company's own job postings stay: a business's postings are not
personal data.

This can't be undone.

## Where it lives in the code

- `Core.Behaviour.Sources` and `Core.Behaviour.Log` — what writes an
  observation;
- `Core.Behaviour.Privacy` — the sweep and *Forget*;
- `Core.Access.Behaviour` — who sees and who may forget.
