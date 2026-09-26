import { pageTitle } from 'ember-page-title';
import Editor from 'fumoco/components/editor';

<template>
  {{pageTitle "Fumoco"}}

  <Editor />

  {{outlet}}
</template>
