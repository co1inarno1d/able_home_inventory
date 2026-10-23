#!/usr/bin/env python3
"""
Extract customer identity signals out of schedule events.

WHY THIS EXISTS
Able Home's schedule lives in QuickBooks Time. An event's *title* is almost
always a TOWN plus a job type -- "Boylston Install", "Fitchburg SL service" --
not a customer name. The customer's identity is scattered across:

  * `location`  -- the street address, on ~56% of events
  * `notes`     -- a free-text blob that usually holds the customer's name and
                   phone, sometimes a funding source, equipment, and an
                   address repeated from the location field

So building a customer list means reading the notes. This module does the
reading; grouping and scoring happen in match.py.

DESIGN RULE
Every extractor returns what it is confident about and leaves the rest blank.
A blank is a visible gap that review can fill. A wrong value silently attaches
one household's history to another, which is the failure mode that actually
matters here -- a tech seeing the wrong service history is worse than a tech
seeing none.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Phone numbers
# ---------------------------------------------------------------------------

# Deliberately strict: requires a 3-3-4 shape with a recognised separator.
# Loose patterns match quote numbers, serial numbers and VA reference codes,
# all of which appear in these notes.
_PHONE = re.compile(
    r"(?<![\d-])"                       # not mid-number
    r"(?:\+?1[-.\s]?)?"                 # optional country code
    r"(?:\((\d{3})\)|(\d{3}))"          # area code, bracketed or not
    r"[-.\s]?"
    r"(\d{3})"
    r"[-.\s]?"
    r"(\d{4})"
    r"(?![\d-])"
)

# Area codes that are not real. 555 is fictional; 000/111 are placeholders.
_BAD_AREA = {"000", "111", "555"}


def extract_phones(text: str) -> list[str]:
    """Every plausible US phone number in `text`, as E.164, order preserved.

    Mirrors the SQL normalize_e164() so Python and Postgres agree on what a
    number looks like.
    """
    if not text:
        return []
    out: list[str] = []
    for m in _PHONE.finditer(text):
        area = m.group(1) or m.group(2)
        if area in _BAD_AREA or area.startswith("0") or area.startswith("1"):
            continue
        e164 = f"+1{area}{m.group(3)}{m.group(4)}"
        if e164 not in out:
            out.append(e164)
    return out


# ---------------------------------------------------------------------------
# Addresses
# ---------------------------------------------------------------------------

_STREET_SUFFIX = {
    "st": "st", "street": "st",
    "rd": "rd", "road": "rd",
    "ave": "ave", "avenue": "ave", "av": "ave",
    "dr": "dr", "drive": "dr",
    "ln": "ln", "lane": "ln",
    "ct": "ct", "court": "ct",
    "cir": "cir", "circle": "cir",
    "blvd": "blvd", "boulevard": "blvd",
    "ter": "ter", "terrace": "ter",
    "pl": "pl", "place": "pl",
    "way": "way", "hwy": "hwy", "highway": "hwy",
    "pkwy": "pkwy", "parkway": "pkwy",
    "sq": "sq", "square": "sq",
    "trl": "trl", "trail": "trl",
    "run": "run", "row": "row", "path": "path", "glen": "glen",
    "hollow": "hollow", "ext": "ext",
}

_UNIT_WORDS = re.compile(
    r"\b(?:apt|apartment|unit|ste|suite|#|rm|room|fl|floor|bldg|building)\b\.?\s*"
    r"([\w-]+)",
    re.I,
)

_DIRECTIONAL = {
    "n": "n", "north": "n", "s": "s", "south": "s",
    "e": "e", "east": "e", "w": "w", "west": "w",
    "ne": "ne", "nw": "nw", "se": "se", "sw": "sw",
}


def _strip_accents(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)
    )


@dataclass
class Address:
    raw: str = ""
    house: str = ""        # leading house number
    street: str = ""       # normalized street name + suffix
    unit: str = ""         # apt/unit, kept separate
    city: str = ""
    state: str = ""
    key: str = ""          # grouping key: "house|street|city"

    @property
    def is_usable(self) -> bool:
        """True when there is enough to identify a specific building."""
        return bool(self.house and self.street)


def parse_address(raw: str) -> Address:
    """Parse a free-text address into its grouping parts.

    Accepts the shapes that actually appear in this data, e.g.
      '39 Ingleside Ave, Winthrop, MA'
      '52 homefield Avenue Dracut Ma'
      '84 Freedom Hollow, Salem, MA, United States'
    """
    addr = Address(raw=(raw or "").strip())
    if not addr.raw:
        return addr

    s = _strip_accents(addr.raw).lower()
    s = s.replace("united states", " ").replace("usa", " ")
    s = re.sub(r"\s+", " ", s).strip(" ,.")

    # Pull the unit out before anything else, so "apt 2" never becomes part of
    # the street name and split one household into two.
    unit_match = _UNIT_WORDS.search(s)
    if unit_match:
        addr.unit = unit_match.group(1).strip(" ,.")
        s = _UNIT_WORDS.sub(" ", s)
        s = re.sub(r"\s+", " ", s).strip(" ,.")

    # Trailing 2-letter state, with or without a comma.
    st = re.search(r"[,\s]([a-z]{2})\s*(?:\d{5}(?:-\d{4})?)?$", s)
    if st and st.group(1) in {
        "ma", "ri", "nh", "ct", "vt", "me", "ny",
    }:
        addr.state = st.group(1)
        s = s[: st.start()].strip(" ,.")

    # Drop a zip anywhere it survived.
    s = re.sub(r"\b\d{5}(?:-\d{4})?\b", " ", s)
    s = re.sub(r"\s+", " ", s).strip(" ,.")

    parts = [p.strip() for p in s.split(",") if p.strip()]
    if len(parts) >= 2:
        # "39 ingleside ave, winthrop"
        street_part, addr.city = parts[0], parts[-1]
    else:
        # No commas: assume the last word is the town, which holds for
        # "52 homefield avenue dracut".
        words = s.split()
        if len(words) >= 3:
            street_part, addr.city = " ".join(words[:-1]), words[-1]
        else:
            street_part, addr.city = s, ""

    m = re.match(r"^(\d+[a-z]?)\s+(.*)$", street_part)
    if not m:
        return addr
    addr.house = m.group(1)
    street_words = m.group(2).split()

    # Normalize the directional prefix and the street suffix so
    # "34 E Springfield St" and "34 east springfield street" collide.
    norm: list[str] = []
    for i, w in enumerate(street_words):
        w = w.strip(".,")
        if not w:
            continue
        if i == 0 and w in _DIRECTIONAL:
            norm.append(_DIRECTIONAL[w])
        elif i == len(street_words) - 1 and w in _STREET_SUFFIX:
            norm.append(_STREET_SUFFIX[w])
        else:
            norm.append(w)
    addr.street = " ".join(norm)
    addr.city = addr.city.strip(" ,.")
    if addr.is_usable:
        addr.key = f"{addr.house}|{addr.street}|{addr.city}"
    return addr


# ---------------------------------------------------------------------------
# Person names
# ---------------------------------------------------------------------------

# Words that mark a line as something other than a customer's name. Built from
# reading the real notes: funding sources, equipment, our own staff, and the
# vocabulary of the job itself.
_NOT_A_NAME = {
    # funding / agency
    "private", "pay", "va", "vamc", "ccals", "navicare", "summit", "fallon",
    "mass", "health", "masshealth", "medicaid", "medicare", "quote", "number",
    "insurance", "agency", "veteran", "vet", "stavros", "tufts", "elder",
    "services", "council", "aging", "housing", "authority",
    # equipment
    "bruno", "acorn", "harmar", "brooks", "elan", "elite", "stairlift", "sl",
    "vpl", "ramp", "ramps", "lift", "lifts", "curve", "curved", "straight",
    "rail", "rails", "battery", "batteries", "remote", "charger", "seat",
    "swivel", "footrest", "recon", "reconditioned", "used", "new", "model",
    "serial", "ryan", "job", "jobs", "savaria", "stannah", "handicare",
    "platform", "section", "sections", "foot", "wood", "aluminum",
    "indoor", "outdoor", "unit", "units",
    # job words
    "install", "installed", "removal", "remove", "removed", "service",
    "eval", "evaluation", "annual", "inspection", "repair", "quote", "buyback",
    "buyout", "rental", "delivery", "pickup", "prep", "warranty", "estimate",
    "call", "called", "lm", "left", "message", "voicemail", "scheduled",
    "set", "setup", "confirm", "confirmed", "cancel", "cancelled",
    # places / directions
    "street", "road", "ave", "avenue", "drive", "lane", "court", "circle",
    "first", "second", "third", "floor", "front", "back", "entrance",
    "basement", "garage", "stairs", "landing", "door",
    # our people (so a tech's name is never taken as the customer)
    "steve", "matt", "chris", "colin", "jeff",
}

# Labeled fields on VA / CCALS intake forms pasted into notes.
_LABELED_NAME = re.compile(
    r"(?:end[-\s]?user|patient|customer|client|vet(?:eran)?|member)"
    r"(?:\s+(?:first|last|full))?\s*name\s*:\s*([^\n|]+)",
    re.I,
)
_FIRST_LAST = re.compile(
    r"end[-\s]?user\s+first\s+name\s*:\s*([^\n|]+?)\s*(?:\||\n)"
    r".*?end[-\s]?user\s+last\s+name\s*:\s*([^\n|]+)",
    re.I | re.S,
)

# A bare name line: 2-3 capitalized words, optional suffix. Requires original
# capitalization, which is a real signal in these notes -- names are
# capitalized, job shorthand usually is not.
_NAME_LINE = re.compile(
    r"^([A-Z][a-zA-Z'’\-]+(?:\s+[A-Z][a-zA-Z'’\-\.]+){1,2}"
    r"(?:\s+(?:Jr|Sr|II|III|IV)\.?)?)$"
)

# "Zach Taylor 978-360-9213" / "Rose Gervais 508-320-1232" -- a name directly
# followed by a phone number. Anchored at line start so a name mentioned
# mid-sentence is not harvested.
_NAME_THEN_PHONE = re.compile(
    r"^([A-Z][a-zA-Z'’\-]+(?:\s+[A-Z][a-zA-Z'’\-\.]+){1,2}"
    r"(?:\s+(?:Jr|Sr|II|III|IV)\.?)?)"
    r"\s+(?:\+?1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}\b"
)

_TITLE_PREFIX = re.compile(r"^(?:mr|mrs|ms|miss|dr|rev)\.?\s+", re.I)

# Verbs that precede a customer's name in these notes and would otherwise be
# captured as a first name -- "Meet Diane Baruch", "Call Rose Gervais". Found
# by auditing addresses that produced two different names for one household.
_LEADING_VERB = re.compile(
    r"^(?:meet|call|called|contact|see|text|email|visit|ask|confirm|"
    r"talk\s+to|speak\s+(?:to|with)|lm\s+(?:for|to))\s+",
    re.I,
)


def _looks_like_person(name: str) -> bool:
    """Reject lines whose words mark them as non-names."""
    words = [w.strip(".,'’-").lower() for w in name.split()]
    words = [w for w in words if w]
    if len(words) < 2 or len(words) > 4:
        return False
    if any(w in _NOT_A_NAME for w in words):
        return False
    if any(any(ch.isdigit() for ch in w) for w in words):
        return False
    # A single letter is an initial, fine; but not every word.
    if all(len(w) <= 1 for w in words):
        return False
    return True


def extract_names(notes: str) -> list[str]:
    """Candidate customer names from a notes blob, best first.

    Labeled intake fields are trusted over bare lines, because they say what
    they are.
    """
    if not notes:
        return []
    out: list[str] = []

    def add(n: str) -> None:
        n = n.strip(" ,.|")
        n = _LEADING_VERB.sub("", n)
        n = _TITLE_PREFIX.sub("", n)
        n = re.sub(r"\s+", " ", n)
        if n and _looks_like_person(n) and n not in out:
            out.append(n)

    # Strongest: an explicit First + Last pair from a form.
    fl = _FIRST_LAST.search(notes)
    if fl:
        add(f"{fl.group(1).strip()} {fl.group(2).strip()}")

    # Next: any single labeled name field.
    for m in _LABELED_NAME.finditer(notes):
        add(m.group(1))

    # Finally: capitalized name-shaped text, in the order it appears. The
    # customer's name is usually the first thing in the note.
    for raw_line in re.split(r"\||\n", notes):
        line = raw_line.strip(" ,.")
        if not line:
            continue

        line = _LEADING_VERB.sub("", line)

        # A name sitting alone on its line.
        if len(line) <= 40:
            m = _NAME_LINE.match(line)
            if m:
                add(m.group(1))
                continue

        # A name immediately followed by its phone number, which is how most
        # of these notes are actually written: "Zach Taylor 978-360-9213".
        # Without this, the most common layout in the data yields nothing.
        m = _NAME_THEN_PHONE.match(line)
        if m:
            add(m.group(1))

    return out


# ---------------------------------------------------------------------------
# Job classification for no-address events
# ---------------------------------------------------------------------------

# Colin's instruction: flag anything that could plausibly be an eval, install,
# service or removal of a stairlift or ramp. Everything else is assumed to be
# a note and left alone, because most of it genuinely is ("Chimney sweep",
# "Leave from home", "Check Subaru").
_REAL_WORK = re.compile(
    r"\b(?:install|installed|installation|removal|remove|removed|service|"
    r"serviced|eval|evaluation|repair|annual|inspection|warranty|adjust|"
    r"buyback|buyout|rental|vpl|stairlift|\bsl\b|ramp)\b",
    re.I,
)
# Phrases that look like work but are internal errands.
_INTERNAL = re.compile(
    r"\b(?:leave from home|go to|meet |pick up lunch|store|shop|truck|"
    r"subaru|van|gas|dump|lowes|home depot|office|vacation|holiday|"
    r"day off|pto|sick|lunch|meeting|chimney|toilet ring)\b",
    re.I,
)


def looks_like_customer_work(title: str, notes: str = "") -> bool:
    """True when an event probably represents work at a customer's home.

    Used to decide whether a missing address is worth flagging. Errs toward
    False: a false positive creates a cleanup task for a non-job.
    """
    text = f"{title} {notes}"
    if _INTERNAL.search(title or ""):
        return False
    return bool(_REAL_WORK.search(text))


# ---------------------------------------------------------------------------
# One event's worth of extracted signal
# ---------------------------------------------------------------------------


@dataclass
class EventSignals:
    tsheets_id: str
    title: str
    start_time: str
    address: Address
    phones: list[str] = field(default_factory=list)
    names: list[str] = field(default_factory=list)
    # True when this looks like customer work but has no usable address, so it
    # cannot be grouped and should be surfaced for an address to be added.
    needs_address: bool = False

    @property
    def best_name(self) -> str:
        return self.names[0] if self.names else ""

    @property
    def identifiable(self) -> bool:
        """Can this event be attached to a household at all?"""
        return self.address.is_usable or bool(self.phones)


def extract_event(row: dict) -> EventSignals:
    """Pull every identity signal out of one schedule_history row."""
    title = row.get("title") or ""
    notes = row.get("notes") or ""
    location = row.get("location") or ""

    addr = parse_address(location)
    # The notes sometimes repeat the address when the location field is empty.
    if not addr.is_usable and notes:
        for line in re.split(r"\||\n", notes):
            cand = parse_address(line)
            if cand.is_usable:
                addr = cand
                break

    sig = EventSignals(
        tsheets_id=str(row.get("tsheets_id") or ""),
        title=title,
        start_time=row.get("start_time") or "",
        address=addr,
        phones=extract_phones(notes) or extract_phones(location),
        names=extract_names(notes),
    )
    sig.needs_address = (
        not sig.address.is_usable and looks_like_customer_work(title, notes)
    )
    return sig
