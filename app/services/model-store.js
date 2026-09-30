// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import Service, { service } from '@ember/service';
import { tracked } from '@glimmer/tracking';
import { FmcModel } from 'fumoco/utils/fmc-model';

const AUTOSAVE_KEY = 'fumoco:autosave';
const AUTOSAVE_DEBOUNCE_MS = 500;
// Undo is snapshot-based: the whole model's JSON before a change. Changes
// closer together than this (a joint move's several mutations, typing a
// name) are one undo step.
const UNDO_COALESCE_MS = 600;
// ponytail: whole-model snapshots, capped; diffs if models ever get huge.
const UNDO_LIMIT = 100;

export default class ModelStoreService extends Service {
  @service fileIo;

  @tracked model = FmcModel.fromJSON(this._loadAutosave() ?? {});
  @tracked activeViewId = null;

  #autosaveTimer = null;
  #lastMutationAt = 0;
  undoCoalesceMs = UNDO_COALESCE_MS; // tests set -1: every change its own step

  // JSON strings of earlier/later model states.
  @tracked undoStack = [];
  @tracked redoStack = [];

  get canUndo() {
    return this.undoStack.length > 0;
  }

  get canRedo() {
    return this.redoStack.length > 0;
  }

  undo() {
    if (!this.canUndo) return;
    this.redoStack = [...this.redoStack, this._snapshot()];
    this._restore(this.undoStack.at(-1));
    this.undoStack = this.undoStack.slice(0, -1);
  }

  redo() {
    if (!this.canRedo) return;
    this.undoStack = [...this.undoStack, this._snapshot()];
    this._restore(this.redoStack.at(-1));
    this.redoStack = this.redoStack.slice(0, -1);
  }

  get activeView() {
    return this.activeViewId ? this.model.views.get(this.activeViewId) : null;
  }

  // Every mutating action funnels through here so autosave stays current
  // without every call site remembering to trigger it. Also stamps the
  // active view's `updatedAt` -- a best-effort "last edited" rather than
  // precise per-view dirty tracking (see View's own comment in
  // fmc-model.js), but good enough for the properties panel to show
  // something meaningful without every call site remembering to bump it.
  mutate(fn) {
    const now = Date.now();
    if (now - this.#lastMutationAt > this.undoCoalesceMs) this._recordUndo();
    this.#lastMutationAt = now;
    const result = fn(this.model);
    if (this.activeView) this.activeView.updatedAt = new Date().toISOString();
    this._scheduleAutosave();
    return result;
  }

  newModel() {
    this._recordUndo();
    this.model = new FmcModel();
    this.activeViewId = null;
    this._scheduleAutosave();
  }

  async open() {
    const json = await this.fileIo.open();
    this._recordUndo();
    this.model = FmcModel.fromJSON(json);
    this.activeViewId = [...this.model.views.keys()][0] ?? null;
    this._scheduleAutosave();
  }

  async save() {
    await this.fileIo.save(this.model.toJSON());
  }

  async saveAs() {
    await this.fileIo.saveAs(this.model.toJSON());
  }

  _snapshot() {
    return JSON.stringify(this.model.toJSON());
  }

  _recordUndo() {
    this.undoStack = [...this.undoStack, this._snapshot()].slice(-UNDO_LIMIT);
    this.redoStack = [];
  }

  _restore(snapshot) {
    this.model = FmcModel.fromJSON(JSON.parse(snapshot));
    if (!this.model.views.has(this.activeViewId)) {
      this.activeViewId = [...this.model.views.keys()][0] ?? null;
    }
    this.#lastMutationAt = 0; // the next change starts a new undo step
    this._scheduleAutosave();
  }

  _loadAutosave() {
    try {
      const raw = localStorage.getItem(AUTOSAVE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  _scheduleAutosave() {
    clearTimeout(this.#autosaveTimer);
    this.#autosaveTimer = setTimeout(() => {
      try {
        localStorage.setItem(AUTOSAVE_KEY, JSON.stringify(this.model.toJSON()));
      } catch {
        // localStorage unavailable (private browsing, quota, ...) -- autosave
        // is a convenience, not the source of truth, so fail silently.
      }
    }, AUTOSAVE_DEBOUNCE_MS);
  }
}
