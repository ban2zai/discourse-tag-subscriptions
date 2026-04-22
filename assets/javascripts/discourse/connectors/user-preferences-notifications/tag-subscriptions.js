import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { schedule } from "@ember/runloop";

const LEVEL_MAP = {
  watching_first_post: { saveField: "watching_first_post_tags" },
  watching:            { saveField: "watched_tags" },
  tracking:            { saveField: "tracked_tags" },
};

const ALL_TAG_FIELDS = [
  "watching_first_post_tags",
  "watched_tags",
  "tracked_tags",
];

export default class TagSubscriptions extends Component {
  @service siteSettings;

  @tracked tagGroups = [];
  @tracked selectedNames = new Set();
  @tracked expandedGroups = new Set();
  @tracked isLoading = true;

  // {tagName: fieldName} — исходный уровень каждого тега для сохранения неуправляемых тегов
  _initialFieldMap = {};
  _saveHandler = null;
  _saveBtn = null;
  _observer = null;
  _displayNameCache = {};

  get notificationLevel() {
    return this.siteSettings.tag_subscription_notification_level || "watching_first_post";
  }

  get levelConfig() {
    return LEVEL_MAP[this.notificationLevel] || LEVEL_MAP.watching_first_post;
  }

  get levelLabel() {
    const labels = {
      watching_first_post: "Наблюдение (первый пост)",
      watching: "Наблюдение (все ответы)",
      tracking: "Отслеживание",
    };
    return labels[this.notificationLevel] || this.notificationLevel;
  }

  constructor() {
    super(...arguments);
    this.loadData();
    schedule("afterRender", this, this._hookSaveButton);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this._unhookSaveButton();
  }

  // ─── Display name из CSS ::before ─────────────────────────────────────────

  @action
  displayName(slug) {
    if (this._displayNameCache[slug] !== undefined) {
      return this._displayNameCache[slug];
    }

    const probe = document.createElement("a");
    probe.className = "discourse-tag";
    probe.dataset.tagName = slug;
    probe.style.cssText =
      "position:absolute;left:-9999px;top:-9999px;pointer-events:none;visibility:hidden;";
    document.body.appendChild(probe);

    const before = window.getComputedStyle(probe, "::before");
    let display = before?.content;

    document.body.removeChild(probe);

    if (display && display !== "none" && display !== "normal" && display !== '""') {
      display = display.replace(/^["']|["']$/g, "");
      this._displayNameCache[slug] = display;
      return display;
    }

    this._displayNameCache[slug] = slug;
    return slug;
  }

  // ─── Хук на кнопку «Сохранить изменения» ──────────────────────────────────

  _hookSaveButton() {
    const btn = document.querySelector(".save-button .save-changes");
    if (btn) {
      this._attachToButton(btn);
      return;
    }
    this._observer = new MutationObserver(() => {
      if (this.isDestroying || this.isDestroyed) {
        this._observer.disconnect();
        return;
      }
      const b = document.querySelector(".save-button .save-changes");
      if (b) {
        this._observer.disconnect();
        this._observer = null;
        this._attachToButton(b);
      }
    });
    this._observer.observe(document.body, { childList: true, subtree: true });
  }

  _attachToButton(btn) {
    this._saveBtn = btn;
    this._saveHandler = () => this._doSave();
    btn.addEventListener("click", this._saveHandler, true);
    console.log("[tsub] хук на .save-changes установлен");
  }

  _unhookSaveButton() {
    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    }
    if (this._saveBtn && this._saveHandler) {
      this._saveBtn.removeEventListener("click", this._saveHandler, true);
    }
    this._saveBtn = null;
    this._saveHandler = null;
  }

  // ─── Загрузка ───────────────────────────────────────────────────────────────

  async loadData() {
    this.isLoading = true;
    try {
      const username = this.args.outletArgs?.model?.username;

      const [tagsResp, userResp] = await Promise.all([
        ajax("/tags.json"),
        ajax(`/u/${username}.json`),
      ]);

      const rawGroups = tagsResp.extras?.tag_groups || [];
      this.tagGroups = this.buildGroups(rawGroups);

      const u = userResp.user || {};
      const toNames = (arr) =>
        (arr || []).map((t) => (typeof t === "string" ? t : t.name));

      // Строим карту {тег: поле} для сохранения оригинальных уровней
      const fieldMap = {};
      for (const field of ALL_TAG_FIELDS) {
        for (const name of toNames(u[field])) {
          fieldMap[name] = field;
        }
      }
      this._initialFieldMap = fieldMap;
      this.selectedNames = new Set(Object.keys(fieldMap));
    } catch (e) {
      console.error("[tsub] ошибка загрузки:", e);
    } finally {
      this.isLoading = false;
    }
  }

  buildGroups(rawGroups) {
    const configured = (this.siteSettings.tag_subscription_groups || "")
      .split("|")
      .map((s) => s.trim())
      .filter(Boolean);

    if (!configured.length) return [];

    return rawGroups
      .filter((g) => configured.includes(g.name))
      .map((g) => ({ name: g.name, tags: g.tags || [] }))
      .filter((g) => g.tags.length > 0);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  @action isSelected(name) {
    return this.selectedNames.has(name);
  }
  @action isExpanded(name) {
    return this.expandedGroups.has(name);
  }

  @action
  sectionState(group) {
    const subSel = group.tags.filter((t) =>
      this.selectedNames.has(t.name)
    ).length;
    const total = group.tags.length;
    if (subSel === 0) return "none";
    if (subSel === total) return "all";
    return "some";
  }

  @action
  subTagSelectedCount(group) {
    return group.tags.filter((t) => this.selectedNames.has(t.name)).length;
  }

  get totalSelected() {
    return this.selectedNames.size;
  }

  // ─── Действия ─────────────────────────────────────────────────────────────

  @action
  toggleExpanded(name) {
    const next = new Set(this.expandedGroups);
    next.has(name) ? next.delete(name) : next.add(name);
    this.expandedGroups = next;
  }

  @action
  toggleTag(name) {
    const next = new Set(this.selectedNames);
    next.has(name) ? next.delete(name) : next.add(name);
    this.selectedNames = next;
  }

  @action
  toggleSection(group) {
    const next = new Set(this.selectedNames);
    const allSelected = group.tags.every((t) => next.has(t.name));
    if (allSelected) {
      group.tags.forEach((t) => next.delete(t.name));
    } else {
      group.tags.forEach((t) => next.add(t.name));
    }
    this.selectedNames = next;
  }

  @action
  deselectAllInGroup(group) {
    const next = new Set(this.selectedNames);
    group.tags.forEach((t) => next.delete(t.name));
    this.selectedNames = next;
  }

  // ─── Сохранение ───────────────────────────────────────────────────────────

  async _doSave() {
    try {
      const username = this.args.outletArgs?.model?.username;

      const allManaged = new Set(
        this.tagGroups.flatMap((g) => g.tags.map((t) => t.name))
      );
      const saveField = this.levelConfig.saveField;

      // Для каждого поля собираем итоговый список тегов
      const tagLists = {};
      for (const field of ALL_TAG_FIELDS) {
        tagLists[field] = [];
      }

      // Управляемые выбранные теги → в saveField
      for (const name of this.selectedNames) {
        if (allManaged.has(name)) {
          tagLists[saveField].push(name);
        }
      }

      // Неуправляемые теги → обратно в их оригинальные поля
      for (const [name, origField] of Object.entries(this._initialFieldMap)) {
        if (!allManaged.has(name)) {
          tagLists[origField].push(name);
        }
      }

      const params = new URLSearchParams();
      for (const field of ALL_TAG_FIELDS) {
        params.set(field, tagLists[field].join(","));
      }
      params.set("muted_tags", "");

      await ajax(`/u/${username}.json`, {
        type: "PUT",
        contentType: "application/x-www-form-urlencoded; charset=UTF-8",
        data: params.toString(),
      });

      // Обновляем карту под новое состояние
      const newMap = {};
      for (const name of this.selectedNames) {
        if (allManaged.has(name)) {
          newMap[name] = saveField;
        }
      }
      for (const [name, origField] of Object.entries(this._initialFieldMap)) {
        if (!allManaged.has(name)) {
          newMap[name] = origField;
        }
      }
      this._initialFieldMap = newMap;

      console.log("[tsub] сохранено, уровень:", this.notificationLevel);
    } catch (e) {
      console.error("[tsub] ошибка сохранения:", e);
    }
  }
}
