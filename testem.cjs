// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

'use strict';

const chromeArgs = {
  ci: [
    // --no-sandbox is needed when running Chrome inside a container
    process.env.CI ? '--no-sandbox' : null,
    '--headless',
    '--disable-dev-shm-usage',
    '--disable-software-rasterizer',
    '--mute-audio',
    '--remote-debugging-port=0',
    '--window-size=1440,900',
  ].filter(Boolean),
};

if (typeof module !== 'undefined') {
  module.exports = {
    test_page: 'tests/index.html?hidepassed',
    disable_watching: true,
    launch_in_ci: ['Chrome'],
    launch_in_dev: ['Chrome'],
    browser_start_timeout: 120,
    browser_args: {
      Chrome: chromeArgs,
      // Linux boxes without Chrome: `npm test -- --launch Chromium`
      Chromium: chromeArgs,
    },
  };
}
