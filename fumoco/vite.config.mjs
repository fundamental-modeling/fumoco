// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import { defineConfig } from 'vite';
import { extensions, classicEmberSupport, ember } from '@embroider/vite';
import { babel } from '@rollup/plugin-babel';

export default defineConfig({
  server: { allowedHosts: ['duncan', 'duncan.fritz.box'] },
  plugins: [
    classicEmberSupport(),
    ember(),
    // extra plugins here
    babel({
      babelHelpers: 'runtime',
      extensions,
    }),
  ],
});
