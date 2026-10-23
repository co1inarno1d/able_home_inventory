#!/usr/bin/env python3
"""
Group extracted schedule events into households.

WHAT THIS DOES
Takes the per-event signals from extract.py and decides which events belong to
the same customer. The output is a set of clusters, each with a confidence, so
the confident ones can be accepted automatically and the rest sent to review.

THE RULE THAT GOVERNS EVERYTHING HERE
    a phone/address MATCH    is strong evidence to MERGE
    a phone/address MISMATCH is NOT evidence to SPLIT

Measured in this data: 12% of addresses already show two or more different
phone numbers (spouse's mobile, a daughter coordinating for a parent, landline
plus cell). Treating "different number" as "different person" would split
roughly one in eight repeat households into duplicates -- and those repeat
households hold the service history worth having.

Conversely a NAME is never an identity. john burke, scott hill and kimm
simpson each appear at 3-4 unrelated addresses in this data. A shared name
with nothing else agreeing is not a match.

WHY UNION-FIND
Identity here is transitive: event A shares a phone with B, B shares an
address with C, so A/B/C are one household even though A and C have nothing
directly in common. That is exactly what union-find expresses, and it avoids
the ordering bugs that pairwise merging produces.
"""

from __future__ import annotations

import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field

from extract import EventSignals, street_key

# ---------------------------------------------------------------------------
# Union-find
# ---------------------------------------------------------------------------


class _DisjointSet:
    """Minimal union-find with path compression."""

    def __init__(self) -> None:
        self._parent: dict[str, str] = {}

    def add(self, x: str) -> None:
        self._parent.setdefault(x, x)

    def find(self, x: str) -> str:
        self.add(x)
        root = x
        while self._parent[root] != root:
            root = self._parent[root]
        # compress
        while self._parent[x] != root:
            self._parent[x], x = root, self._parent[x]
        return root

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self._parent[rb] = ra

    def groups(self) -> dict[str, list[str]]:
        out: dict[str, list[str]] = defaultdict(list)
        for x in self._parent:
            out[self.find(x)].append(x)
        return out


# ---------------------------------------------------------------------------
# Name normalization — for COMPARISON only, never for display
# ---------------------------------------------------------------------------

# Nickname pairs seen in this data plus the common ones. Used to recognise
# that two spellings may be one person -- NOT to rewrite anyone's name.
_NICKNAMES = {
    "phil": "philip", "philip": "philip", "phillip": "philip",
    "bob": "robert", "rob": "robert", "bobby": "robert", "robert": "robert",
    "bill": "william", "billy": "william", "will": "william",
    "william": "william",
    "dick": "richard", "rick": "richard", "rich": "richard",
    "richard": "richard", "richie": "richard",
    "jim": "james", "jimmy": "james", "james": "james", "jamie": "james",
    "mike": "michael", "mikey": "michael", "michael": "michael",
    "dave": "david", "david": "david",
    "dan": "daniel", "danny": "daniel", "daniel": "daniel",
    "joe": "joseph", "joey": "joseph", "joseph": "joseph",
    "tom": "thomas", "tommy": "thomas", "thomas": "thomas",
    "steve": "stephen", "stephen": "stephen", "steven": "stephen",
    "ed": "edward", "eddie": "edward", "edward": "edward",
    "ted": "edward", "teddy": "edward",
    "tony": "anthony", "anthony": "anthony",
    "chuck": "charles", "charlie": "charles", "charles": "charles",
    "ken": "kenneth", "kenny": "kenneth", "kenneth": "kenneth",
    "sue": "susan", "susie": "susan", "susan": "susan",
    "suzanne": "susan", "suzy": "susan",
    "kathy": "katherine", "cathy": "katherine", "kate": "katherine",
    "katherine": "katherine", "catherine": "katherine", "kathleen": "katherine",
    "peggy": "margaret", "maggie": "margaret", "margaret": "margaret",
    "betty": "elizabeth", "beth": "elizabeth", "liz": "elizabeth",
    "elizabeth": "elizabeth",
    "jen": "jennifer", "jenny": "jennifer", "jennifer": "jennifer",
    "deb": "deborah", "debbie": "deborah", "deborah": "deborah",
    "pat": "patricia", "patty": "patricia", "patricia": "patricia",
    "cindy": "cynthia", "cyndy": "cynthia", "cynthia": "cynthia",
    "judy": "judith", "judith": "judith",
    "charleen": "charlene", "charlene": "charlene",
    "maryann": "mary ann", "marianne": "mary ann",
}

_SUFFIXES = {"jr", "sr", "ii", "iii", "iv"}


def norm_name(name: str) -> str:
    """Canonical comparison form of a person's name.

    Lowercases, drops punctuation and generational suffixes, and maps the first
    name through the nickname table. Returned value is for matching only.
    """
    if not name:
        return ""
    words = [w.strip(".,'’-").lower() for w in name.split()]
    words = [w for w in words if w and w not in _SUFFIXES]
    if not words:
        return ""
    words[0] = _NICKNAMES.get(words[0], words[0])
    return " ".join(words)


def surname(name: str) -> str:
    n = norm_name(name)
    return n.split()[-1] if n else ""


def _edit_distance_le(a: str, b: str, limit: int = 1) -> bool:
    """True when `a` and `b` are within `limit` single-character edits.

    Catches the typo variants in this data -- Bourgeault/Bourgeualt,
    McGrath/Mcgrath (after lowercasing), heights/hights -- without pulling in a
    fuzzy-matching dependency.
    """
    if a == b:
        return True
    if abs(len(a) - len(b)) > limit:
        return False
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(
                prev[j] + 1,
                cur[j - 1] + 1,
                prev[j - 1] + (ca != cb),
            )
        prev = cur
        if min(prev) > limit:
            return False
    return prev[-1] <= limit


def names_compatible(a: str, b: str) -> bool:
    """True when two names could plausibly be the same person.

    Deliberately permissive -- this only ever ADDS evidence to a match that
    something else (phone or address) already supports. It never splits.
    """
    na, nb = norm_name(a), norm_name(b)
    if not na or not nb:
        return False
    if na == nb:
        return True
    # Same surname and a compatible first name: "Phil Bourgeault" vs
    # "Philip Bourgeault".
    pa, pb = na.split(), nb.split()
    if pa[-1] == pb[-1] and pa[0][0] == pb[0][0]:
        return True
    # A one-character typo anywhere: "Bourgeault" vs "Bourgeualt".
    if _edit_distance_le(na, nb, 1):
        return True
    # Same surname where one side is a typo of the other.
    if len(pa) >= 2 and len(pb) >= 2 and _edit_distance_le(pa[-1], pb[-1], 1):
        return pa[0][0] == pb[0][0]
    return False


def streets_compatible(a: str, b: str) -> bool:
    """True when two street keys plausibly describe the same building.

    Handles the spelling variants in this data: "182 justice hill cut off" vs
    "cut-off", "48 victoria heights rd" vs "victoria hights road". Requires an
    identical house number -- a different number on the same street is a
    DIFFERENT house, which is the single most common source of silent
    wrong matches.
    """
    if not a or not b:
        return False
    if a == b:
        return True
    ha, sa = a.split("|", 1) if "|" in a else (a, "")
    hb, sb = b.split("|", 1) if "|" in b else (b, "")
    if ha != hb:
        return False
    ca = re.sub(r"[^a-z0-9]", "", sa)
    cb = re.sub(r"[^a-z0-9]", "", sb)
    if ca == cb:
        return True
    # One is a prefix of the other ("44 valentine rd" vs
    # "44 valentine rd northborough" when the town leaked into the street).
    if ca.startswith(cb) or cb.startswith(ca):
        return True
    return _edit_distance_le(ca, cb, 2)


# ---------------------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------------------


@dataclass
class Household:
    """One candidate customer, assembled from events that agree."""

    cluster_id: str
    event_ids: list[str] = field(default_factory=list)
    names: Counter = field(default_factory=Counter)
    phones: Counter = field(default_factory=Counter)
    addresses: Counter = field(default_factory=Counter)
    cities: Counter = field(default_factory=Counter)
    # Who handled this household's agency-funded work, and which agency.
    # Not customers -- recorded so the office knows who to call back.
    agency_contacts: Counter = field(default_factory=Counter)
    agencies: Counter = field(default_factory=Counter)
    first_seen: str = ""
    last_seen: str = ""
    # Why this cluster was formed, for the review CSV.
    evidence: list[str] = field(default_factory=list)

    @property
    def event_count(self) -> int:
        return len(self.event_ids)

    @property
    def best_name(self) -> str:
        """Most frequently seen spelling, which is the best display choice."""
        return self.names.most_common(1)[0][0] if self.names else ""

    @property
    def best_address(self) -> str:
        return self.addresses.most_common(1)[0][0] if self.addresses else ""

    @property
    def best_phone(self) -> str:
        return self.phones.most_common(1)[0][0] if self.phones else ""

    @property
    def best_agency(self) -> str:
        return self.agencies.most_common(1)[0][0] if self.agencies else ""

    @property
    def agency_contact_list(self) -> str:
        return ", ".join(n for n, _ in self.agency_contacts.most_common(3))

    @property
    def distinct_name_forms(self) -> list[str]:
        """Spellings that normalize differently -- a genuine disagreement.

        Phil/Philip collapse and are not counted; Debbie/Mark do not and are.
        """
        seen: dict[str, str] = {}
        for n in self.names:
            seen.setdefault(norm_name(n), n)
        return sorted(seen.values())

    @property
    def confidence(self) -> float:
        """How sure we are this cluster is exactly one customer.

        Scored on what actually distinguishes a safe merge in this data, not on
        a generic similarity metric.
        """
        score = 0.0

        # A single consistent address is the strongest signal available.
        if len(self.addresses) == 1:
            score += 0.45
        elif self.addresses and self._addresses_agree():
            score += 0.35      # spelling variants of one address
        elif self.addresses:
            score += 0.10      # several real addresses: a move, or a mistake

        # A phone shared across the cluster's events.
        if len(self.phones) == 1:
            score += 0.30
        elif self.phones:
            score += 0.20      # several numbers is normal for a household

        # Names agreeing adds confidence; disagreeing withholds it but does
        # NOT subtract, because spouses legitimately disagree.
        forms = self.distinct_name_forms
        if len(forms) == 1:
            score += 0.25
        elif len(forms) > 1:
            score += 0.05

        return round(min(score, 1.0), 3)

    def _addresses_agree(self) -> bool:
        keys = list(self.addresses)
        return all(
            streets_compatible(keys[0], k) for k in keys[1:]
        )

    # ------------------------------------------------------------------
    # Triage
    #
    # "Needs review" on its own was useless: it put 2,146 items in front of
    # Colin, a third of them single-event clusters where the answer is
    # unknowable from the schedule alone. Splitting by WHO can answer the
    # question makes it tractable.
    # ------------------------------------------------------------------

    @property
    def triage(self) -> str:
        """Who can resolve this cluster, and how urgently.

        accept         -- confident enough to link automatically
        confirm_family -- several names sharing a surname at one address, i.e.
                          a family. Obvious at a glance; still confirmed, never
                          merged silently.
        decide         -- genuinely ambiguous: unrelated names at one address,
                          or two real addresses. Needs actual thought.
        await_qb -- the cluster is coherent but has no name. QuickBooks is the
                    authoritative source for names, so asking Colin to type
                    one in is wasted effort; these resolve on the QB
                    cross-reference instead.
        thin     -- a single event with almost no signal. Parking these costs
                    nothing: one event of history, and it stays searchable in
                    the schedule regardless.
        """
        multi_name = len(self.distinct_name_forms) > 1
        multi_addr = len(self.addresses) > 1 and not self._addresses_agree()

        # A real conflict between two identities is Colin's call, always --
        # per his instruction that name variants must never be auto-merged.
        #
        # But not all conflicts are equally hard. When every name in the
        # cluster shares a surname at one address, it is a family: Marshall
        # Mills and Sue Mills, Frances and Paul Sadowski. Those still get
        # confirmed rather than merged silently, but they belong in a
        # fast-confirm lane -- the answer is obvious at a glance, so they
        # should not sit in the same queue as "Darlyn Scott / Donald
        # Bevelander / Gretchen Sting at one address", which needs thought.
        if multi_name and not multi_addr:
            surnames = {surname(n) for n in self.distinct_name_forms}
            if len(surnames) == 1 and len(self.addresses) <= 2:
                return "confirm_family"

        if multi_name or multi_addr:
            return "decide"

        if not self.names:
            # Coherent household, no name. QB knows the name.
            if self.addresses or self.phones:
                return "await_qb"
            return "thin"

        if self.confidence >= 0.70:
            return "accept"

        # Has a name but weak corroboration. One event is not worth asking
        # about; several means there is history at stake.
        return "decide" if self.event_count >= 2 else "thin"

    @property
    def needs_review(self) -> bool:
        """True when this cluster must not be linked without a human."""
        return self.triage == "decide"

    @property
    def review_reason(self) -> str:
        forms = self.distinct_name_forms
        if len(forms) > 1:
            return f"{len(forms)} names at one address: {', '.join(forms[:4])}"
        if len(self.addresses) > 1 and not self._addresses_agree():
            return f"{len(self.addresses)} different addresses — moved, or two households?"
        if not self.names:
            return "no name in the schedule — needs QuickBooks"
        if self.confidence < 0.70:
            return "name found but little corroborating detail"
        return ""


# A signal that links this many distinct OTHER identities is not an identity.
#
# Found the hard way: without this, one cluster grew to 120 events, 29 names
# and 10 addresses. The cause was 67 W Boylston St -- our own shop -- which
# appears on 62 events with 13 different customer names. Because identity is
# transitive, every event touching the shop chained into one giant blob.
#
# The same happens with agency coordinators' phone numbers: one number at 8
# different addresses is a case manager, not a household.
#
# Suppressing these loses the link but keeps the events, which then group on
# their own remaining signals. A missed merge is recoverable in review; a
# blob that swallows 29 households is not.
_MAX_NAMES_PER_ADDRESS = 4
_MAX_ADDRESSES_PER_PHONE = 3


def find_hub_signals(
    sigs: list[EventSignals],
) -> tuple[set[str], set[str]]:
    """Identify addresses and phones too shared to be identities.

    Returns (hub_addresses, hub_phones) as street keys and E.164 numbers.
    """
    addr_names: dict[str, set[str]] = defaultdict(set)
    phone_addrs: dict[str, set[str]] = defaultdict(set)

    for s in sigs:
        sk = street_key(s.address)
        if sk:
            for n in s.names:
                addr_names[sk].add(norm_name(n))
        for p in s.phones:
            if sk:
                phone_addrs[p].add(sk)

    hub_addresses = {
        sk for sk, names in addr_names.items()
        if len(names) > _MAX_NAMES_PER_ADDRESS
    }
    # Count only addresses that are genuinely different buildings, so a
    # household whose address has three spelling variants is not mistaken
    # for a coordinator's phone.
    hub_phones: set[str] = set()
    for p, addrs in phone_addrs.items():
        keys = list(addrs)
        distinct = [
            k for i, k in enumerate(keys)
            if not any(streets_compatible(k, o) for o in keys[:i])
        ]
        if len(distinct) > _MAX_ADDRESSES_PER_PHONE:
            hub_phones.add(p)
    return hub_addresses, hub_phones


def build_households(sigs: list[EventSignals]) -> list[Household]:
    """Cluster events into households.

    Links events that share a phone number or a street address, then merges
    clusters whose street addresses are spelling variants of each other.

    Signals shared across too many distinct identities (our own shop address,
    an agency coordinator's phone) are suppressed as merge links -- see
    find_hub_signals.
    """
    hub_addresses, hub_phones = find_hub_signals(sigs)
    ds = _DisjointSet()

    # Index events by each identity signal they carry.
    by_phone: dict[str, list[str]] = defaultdict(list)
    by_street: dict[str, list[str]] = defaultdict(list)
    sig_by_id: dict[str, EventSignals] = {}

    for s in sigs:
        if not s.identifiable:
            continue
        sig_by_id[s.tsheets_id] = s
        ds.add(s.tsheets_id)
        for p in s.phones:
            if p not in hub_phones:
                by_phone[p].append(s.tsheets_id)
        sk = street_key(s.address)
        if sk and sk not in hub_addresses:
            by_street[sk].append(s.tsheets_id)

    # A shared phone merges. This is the rule that keeps a customer together
    # across a move.
    for ids in by_phone.values():
        for other in ids[1:]:
            ds.union(ids[0], other)

    # A shared address merges. This is what groups a household whose events
    # never recorded a phone.
    for ids in by_street.values():
        for other in ids[1:]:
            ds.union(ids[0], other)

    # Street-spelling variants: only merged when the house number is identical
    # AND the streets are near-identical. Compared within a house-number
    # bucket so this stays linear rather than comparing all pairs.
    by_house: dict[str, list[str]] = defaultdict(list)
    for sk in by_street:
        by_house[sk.split("|", 1)[0]].append(sk)
    for keys in by_house.values():
        for i, a in enumerate(keys):
            for b in keys[i + 1 :]:
                if streets_compatible(a, b):
                    ds.union(by_street[a][0], by_street[b][0])

    # Assemble.
    households: list[Household] = []
    for root, members in ds.groups().items():
        h = Household(cluster_id=root)
        for eid in members:
            s = sig_by_id.get(eid)
            if s is None:
                continue
            h.event_ids.append(eid)
            for n in s.names:
                h.names[n] += 1
            for p in s.phones:
                h.phones[p] += 1
            sk = street_key(s.address)
            if sk:
                h.addresses[sk] += 1
            if s.address.city:
                h.cities[s.address.city] += 1
            for _role, cname in s.agency_contacts:
                h.agency_contacts[cname] += 1
            if s.agency:
                h.agencies[s.agency] += 1
            if s.start_time:
                if not h.first_seen or s.start_time < h.first_seen:
                    h.first_seen = s.start_time
                if not h.last_seen or s.start_time > h.last_seen:
                    h.last_seen = s.start_time
        if h.event_ids:
            if h.phones:
                h.evidence.append("shared phone")
            if h.addresses:
                h.evidence.append("shared address")
            households.append(h)

    households.sort(key=lambda x: (-x.event_count, x.best_name))
    return households
