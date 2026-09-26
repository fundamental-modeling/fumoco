import Service, { service } from '@ember/service';
import { tracked } from '@glimmer/tracking';
import { FmcModel } from 'fumoco/utils/fmc-model';

const AUTOSAVE_KEY = 'fumoco:autosave';
const AUTOSAVE_DEBOUNCE_MS = 500;

export default class ModelStoreService extends Service {
  @service fileIo;

  @tracked model = FmcModel.fromJSON(this._loadAutosave() ?? {});
  @tracked activeViewId = null;

  #autosaveTimer = null;

  get activeView() {
    return this.activeViewId ? this.model.views.get(this.activeViewId) : null;
  }

  // Every mutating action funnels through here so autosave stays current
  // without every call site remembering to trigger it.
  mutate(fn) {
    const result = fn(this.model);
    this._scheduleAutosave();
    return result;
  }

  newModel() {
    this.model = new FmcModel();
    this.activeViewId = null;
    this._scheduleAutosave();
  }

  async open() {
    const json = await this.fileIo.open();
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
