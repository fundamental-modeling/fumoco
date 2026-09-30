// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import { htmlSafe } from '@ember/template';

// Renders a @lucide/icons icon-data object ({ node: [tag, attrs][] }) as an
// inline SVG. @lucide/icons ships icon *data*, not components/markup, so
// this is the small render step lucide's own docs call for on any
// framework without an official wrapper -- not a design of our own.
function renderNode([tag, attrs]) {
  const attrString = Object.entries(attrs)
    .filter(([name]) => name !== 'key')
    .map(([name, value]) => `${name}="${value}"`)
    .join(' ');
  return `<${tag} ${attrString}></${tag}>`;
}

function iconMarkup(icon) {
  return htmlSafe(icon.node.map(renderNode).join(''));
}

<template>
  <svg
    class="icon {{@class}}"
    xmlns="http://www.w3.org/2000/svg"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="2"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >{{iconMarkup @icon}}</svg>
</template>
