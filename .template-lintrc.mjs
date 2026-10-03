// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

export default {
  extends: 'recommended',
  rules: {
    // only a <details>'s <summary> is interactive, not its content
    'no-nested-interactive': { ignoredTags: ['details'] },
  },
};
