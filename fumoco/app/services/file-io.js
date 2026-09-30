// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

// Standalone-browser persistence: File System Access API where available,
// falling back to a download link / <input type=file> pair. Kept as its
// own service (rather than folded into model-store) purely so Milestone D
// can add a vscode-file-io implementation later without touching callers.
import Service from '@ember/service';

export default class FileIoService extends Service {
  #handle = null;

  get supportsFileSystemAccess() {
    return typeof window !== 'undefined' && 'showOpenFilePicker' in window;
  }

  async open() {
    if (this.supportsFileSystemAccess) {
      const [handle] = await window.showOpenFilePicker({
        types: [
          {
            description: 'Fumoco model',
            accept: { 'application/json': ['.fumoco.json', '.json'] },
          },
        ],
      });
      this.#handle = handle;
      const file = await handle.getFile();
      return JSON.parse(await file.text());
    }
    return this._openViaInput();
  }

  async save(json) {
    if (this.supportsFileSystemAccess && this.#handle) {
      await this._writeToHandle(this.#handle, json);
      return;
    }
    await this.saveAs(json);
  }

  async saveAs(json) {
    if (this.supportsFileSystemAccess) {
      const handle = await window.showSaveFilePicker({
        suggestedName: 'model.fumoco.json',
        types: [
          {
            description: 'Fumoco model',
            accept: { 'application/json': ['.fumoco.json'] },
          },
        ],
      });
      this.#handle = handle;
      await this._writeToHandle(handle, json);
      return;
    }
    this._downloadAsFile(json);
  }

  async _writeToHandle(handle, json) {
    const writable = await handle.createWritable();
    await writable.write(JSON.stringify(json, null, 2));
    await writable.close();
  }

  _downloadAsFile(json) {
    const blob = new Blob([JSON.stringify(json, null, 2)], {
      type: 'application/json',
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'model.fumoco.json';
    a.click();
    URL.revokeObjectURL(url);
  }

  _openViaInput() {
    return new Promise((resolve, reject) => {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = '.json,.fumoco.json,application/json';
      input.addEventListener('change', () => {
        const file = input.files?.[0];
        if (!file) return reject(new Error('no file selected'));
        file
          .text()
          .then((text) => resolve(JSON.parse(text)))
          .catch(reject);
      });
      input.click();
    });
  }
}
