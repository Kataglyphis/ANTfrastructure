#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""What each licence in `deps.json` requires of THIS project, as data.

Why this exists
---------------
A licence list that names licences answers "what is in here". It does not answer
the question that actually matters when you publish an image to a public
registry: **what does each of those licences oblige me to do?** Until
2026-08-25 the generated pages carried 97 component rows, zero licence texts and
no corresponding-source offer -- while the published runtime image ships a
GPLv3 FFmpeg (built `--enable-gpl --enable-version3`) and a GPLv3 GCC.

So obligations live here, keyed by SPDX id, and the generator renders them.
Adding a component with an unmapped licence fails the gate rather than silently
producing a row with no obligation attached.

This is a structured reading of licence texts, not legal advice. It is meant to
make the obligations visible and reviewable -- a lawyer's answer still governs,
especially for the proprietary EULAs, where the question is not "what must I
publish" but "may I redistribute this at all".
"""

from __future__ import annotations

# --- obligation codes -------------------------------------------------------
# Each is one thing the distributor must DO. Kept small and concrete so a
# reader can check the image against them.

KEEP_NOTICE = "keep-notice"
INCLUDE_TEXT = "include-text"
STATE_CHANGES = "state-changes"
NOTICE_FILE = "notice-file"
OFFER_SOURCE = "offer-source"
ALLOW_RELINK = "allow-relink"
NETWORK_SOURCE = "network-source"
SAME_LICENCE = "same-licence"
EULA_REVIEW = "eula-review"

DESCRIPTIONS: dict[str, str] = {
    KEEP_NOTICE: "Reproduce the upstream copyright notice with the distributed binary.",
    INCLUDE_TEXT: "Ship the full licence text alongside the binary.",
    STATE_CHANGES: "Mark modified files as changed, and say what was changed.",
    NOTICE_FILE: "Propagate the upstream NOTICE file if one exists.",
    OFFER_SOURCE: (
        "Provide the complete corresponding source, or a written offer valid for "
        "three years. Publishing the binary without either is the obligation most "
        "often missed."
    ),
    ALLOW_RELINK: (
        "Let the recipient replace the library and relink. Shipping it as a shared "
        "object, as this project does, satisfies the mechanism; the notice and text "
        "are still required."
    ),
    NETWORK_SOURCE: (
        "AGPL section 13: users interacting with the software OVER A NETWORK must be "
        "offered its source. This reaches further than the GPL and is worth checking "
        "against how the component is actually exposed."
    ),
    SAME_LICENCE: "Derivative works of this component must carry the same licence.",
    EULA_REVIEW: (
        "Proprietary terms. Redistribution is NOT automatically granted -- the vendor "
        "EULA decides whether this component may ship in a published image at all. "
        "This is a legal question, not a documentation one."
    ),
}

# --- SPDX id -> obligations -------------------------------------------------
# `source_required` marks the families where a corresponding-source pointer is
# mandatory; the generator gates on it for every component that ships.

OBLIGATIONS: dict[str, tuple[str, ...]] = {
    # Permissive
    "MIT": (KEEP_NOTICE, INCLUDE_TEXT),
    "BSD-2-Clause": (KEEP_NOTICE, INCLUDE_TEXT),
    "BSD-3-Clause": (KEEP_NOTICE, INCLUDE_TEXT),
    "BSD-3-Clause-Clear": (KEEP_NOTICE, INCLUDE_TEXT),
    "ISC": (KEEP_NOTICE, INCLUDE_TEXT),
    "Zlib": (KEEP_NOTICE, INCLUDE_TEXT),
    "curl": (KEEP_NOTICE, INCLUDE_TEXT),
    "Unlicense": (),
    "PSF-2.0": (KEEP_NOTICE, INCLUDE_TEXT),
    "NCSA": (KEEP_NOTICE, INCLUDE_TEXT),
    "FTL": (KEEP_NOTICE, INCLUDE_TEXT),
    "Apache-2.0": (KEEP_NOTICE, INCLUDE_TEXT, STATE_CHANGES, NOTICE_FILE),
    "Apache-2.0-with-LLVM-exception": (KEEP_NOTICE, INCLUDE_TEXT, STATE_CHANGES, NOTICE_FILE),
    "ImageMagick": (KEEP_NOTICE, INCLUDE_TEXT, STATE_CHANGES),
    "LPPL-1.3c": (KEEP_NOTICE, INCLUDE_TEXT, STATE_CHANGES),
    "MS-RL": (KEEP_NOTICE, INCLUDE_TEXT, SAME_LICENCE),

    # Weak copyleft -- source required for the component itself
    "LGPL-2.0-or-later": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, ALLOW_RELINK),
    "LGPL-2.1-or-later": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, ALLOW_RELINK),
    "LGPL-3.0-or-later": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, ALLOW_RELINK),
    "MPL-2.0": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES),

    # Strong copyleft
    "GPL-2.0-only": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES, SAME_LICENCE),
    "GPL-2.0-or-later": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES, SAME_LICENCE),
    "GPL-3.0-or-later": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES, SAME_LICENCE),
    # The Runtime Library Exception covers programs COMPILED with GCC. It does
    # not cover shipping GCC itself, which this project's runtime image does.
    "GPL-3.0-or-later-with-GCC-exception": (
        KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES, SAME_LICENCE,
    ),
    "AGPL-3.0-or-later": (
        KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE, STATE_CHANGES, SAME_LICENCE, NETWORK_SOURCE,
    ),

    # Proprietary
    "LicenseRef-Proprietary-EULA": (EULA_REVIEW,),

    # Deliberately coarse: a distro base image or a tool bundle is hundreds of
    # packages under many licences. Their own copyright files travel in the
    # image (/usr/share/doc/*/copyright is not stripped), which is what
    # discharges the notice requirement for them.
    "LicenseRef-Distro-Bundle": (KEEP_NOTICE, INCLUDE_TEXT, OFFER_SOURCE),
}

SOURCE_REQUIRED = frozenset(
    spdx for spdx, obs in OBLIGATIONS.items() if OFFER_SOURCE in obs
)


def obligations_for(expression: str) -> tuple[str, ...]:
    """Union of obligations across an SPDX expression.

    Dual licensing ("Apache-2.0 OR MIT") is rendered as the UNION, not the
    cheaper half: the project has not recorded which arm it elects, so the
    stricter reading is the honest one to display. Record an election in
    deps.json (a single spdx id) to narrow it.
    """
    parts = [
        p.strip()
        for p in expression.replace(" OR ", " AND ").split(" AND ")
        if p.strip()
    ]
    unknown = [p for p in parts if p not in OBLIGATIONS]
    if unknown:
        raise KeyError(
            f"no obligation mapping for {', '.join(unknown)!r} (in {expression!r}). "
            f"Add it to docs/scripts/license_obligations.py."
        )
    out: list[str] = []
    for p in parts:
        for ob in OBLIGATIONS[p]:
            if ob not in out:
                out.append(ob)
    return tuple(out)


def requires_source(expression: str) -> bool:
    return OFFER_SOURCE in obligations_for(expression)
