import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { VpnConfigItem } from './VpnConfigItem';

const STORE_NAME: string = 'vnt_configs';
const KEY_CONFIGS: string = 'configs';
const KEY_SELECTED: string = 'selected';
const KEY_CORE_VERSION: string = 'coreVersion';

export class ConfigStore {
  private prefs: preferences.Preferences | undefined = undefined;

  async init(context: common.Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME);
    } catch (e) {
      this.prefs = undefined;
    }
  }

  async loadAll(): Promise<Array<VpnConfigItem>> {
    if (this.prefs === undefined) {
      return [];
    }
    let list: Array<VpnConfigItem> = [];
    try {
      const raw: preferences.ValueType = this.prefs.getSync(KEY_CONFIGS, '[]');
      if (typeof raw === 'string') {
        list = JSON.parse(raw) as Array<VpnConfigItem>;
      }
    } catch (e) {
      list = [];
    }
    return list;
  }

  async saveAll(list: Array<VpnConfigItem>): Promise<void> {
    if (this.prefs === undefined) {
      return;
    }
    try {
      this.prefs.putSync(KEY_CONFIGS, JSON.stringify(list));
      await this.prefs.flush();
    } catch (e) {
    }
  }

  async loadSelected(): Promise<string> {
    if (this.prefs === undefined) {
      return '';
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(KEY_SELECTED, '');
      if (typeof raw === 'string') {
        return raw;
      }
    } catch (e) {
    }
    return '';
  }

  async saveSelected(id: string): Promise<void> {
    if (this.prefs === undefined) {
      return;
    }
    try {
      this.prefs.putSync(KEY_SELECTED, id);
      await this.prefs.flush();
    } catch (e) {
    }
  }

  async loadCoreVersion(): Promise<string> {
    if (this.prefs === undefined) {
      return 'v1';
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(KEY_CORE_VERSION, 'v1');
      if (raw === 'v2') {
        return 'v2';
      }
    } catch (e) {
    }
    return 'v1';
  }

  async saveCoreVersion(version: string): Promise<void> {
    if (this.prefs === undefined) {
      return;
    }
    try {
      this.prefs.putSync(KEY_CORE_VERSION, version);
      await this.prefs.flush();
    } catch (e) {
    }
  }
}
