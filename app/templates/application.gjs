// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import { pageTitle } from 'ember-page-title';
import Editor from 'fumoco/components/editor';

<template>
  {{pageTitle "Fumoco"}}

  <Editor />

  {{outlet}}
</template>
