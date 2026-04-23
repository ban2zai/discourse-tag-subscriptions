import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { schedule } from "@ember/runloop";
import { htmlSafe } from "@ember/template";

// tagName → Discourse API field
const LEVEL_TO_FIELD = {
  watching_first_post: "watching_first_post_tags",
  watching:            "watched_tags",
  tracking:            "tracked_tags",
};

const FIELD_TO_LEVEL = {
  watching_first_post_tags: "watching_first_post",
  watched_tags:             "watching",
  tracked_tags:             "tracking",
};

function hexToRgba(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return isNaN(r) ? hex : `rgba(${r},${g},${b},${alpha})`;
}

function safeColor(val, fallback) {
  return /^#[0-9a-fA-F]{3,8}$/.test((val || "").trim()) ? val.trim() : fallback;
}

export default class TagSubscriptions extends Component {
  @service siteSettings;

  @tracked tagGroups    = [];
  @tracked selectedLevels = new Map(); // tagName → "watching_first_post" | "watching"
  @tracked expandedGroups = new Set();
  @tracked isLoading    = true;

  _initialLevelMap = new Map(); // tagName → level (все поля, включая неуправляемые)
  _saveHandler  = null;
  _saveBtn      = null;
  _observer     = null;
  _displayNameCache = {};

  // ─── Настройки цветов и текстов ───────────────────────────────────────────

  get _c1() { return safeColor(this.siteSettings.tag_subscription_level1_color, "#e5b000"); }
  get _c2() { return safeColor(this.siteSettings.tag_subscription_level2_color, "#cc5500"); }

  get rootStyle() {
    const c1 = this._c1, c2 = this._c2;
    return htmlSafe(
      `--tsub-c1:${c1};--tsub-c1-bg:${hexToRgba(c1, 0.18)};--tsub-c1-bd:${hexToRgba(c1, 0.5)};` +
      `--tsub-c2:${c2};--tsub-c2-bg:${hexToRgba(c2, 0.18)};--tsub-c2-bd:${hexToRgba(c2, 0.5)};`
    );
  }

  get hintHtml() {
    const custom = (this.siteSettings.tag_subscription_hint || "").trim();
    if (custom) return htmlSafe(custom);
    const sq = (color) =>
      `<span style="display:inline-block;width:11px;height:11px;border-radius:2px;background:${color};vertical-align:middle;margin:0 3px 1px;"></span>`;
    return htmlSafe(
      `Кликните по тегу чтобы указать уровень уведомления. ` +
      `Один клик ${sq(this._c1)}&hairsp;— уведомление о новых темах. ` +
      `Два клика ${sq(this._c2)}&hairsp;— уведомление о каждом новом ответе в теме с тегом.`
    );
  }

  get helpTopicUrl() {
    return this.siteSettings.tag_subscription_help_topic_url || "";
  }

  get helpLinkLabel() {
    return this.siteSettings.tag_subscription_help_link_label || "Инструкция для уведомлений";
  }

  get siteEnabled() {
    return this.siteSettings.tag_subscriptions_enabled !== false;
  }

  get pinnedTags() {
    return (this.siteSettings.tag_subscription_pinned_tags || "")
      .split("|").map((s) => s.trim()).filter(Boolean);
  }

  get pinnedSelectedCount() {
    return this.pinnedTags.filter((name) => this.selectedLevels.has(name)).length;
  }

  get pinnedSectionState() {
    const total = this.pinnedTags.length;
    if (!total) return "none";
    const count = this.pinnedSelectedCount;
    if (count === 0) return "none";
    if (count === total) return "all";
    return "some";
  }

  get totalSelected() { return this.selectedLevels.size; }

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
    if (btn) { this._attachToButton(btn); return; }
    this._observer = new MutationObserver(() => {
      if (this.isDestroying || this.isDestroyed) { this._observer.disconnect(); return; }
      const b = document.querySelector(".save-button .save-changes");
      if (b) { this._observer.disconnect(); this._observer = null; this._attachToButton(b); }
    });
    this._observer.observe(document.body, { childList: true, subtree: true });
  }

  _attachToButton(btn) {
    this._saveBtn = btn;
    this._saveHandler = () => this._doSave();
    btn.addEventListener("click", this._saveHandler, true);
  }

  _unhookSaveButton() {
    if (this._observer) { this._observer.disconnect(); this._observer = null; }
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

      const [groupsResp, userResp] = await Promise.all([
        ajax("/tag-subscriptions/tag-groups.json"),
        ajax(`/u/${username}.json`),
      ]);

      this.tagGroups = this.buildGroups(groupsResp.tag_groups || []);

      const u = userResp.user || {};
      const toNames = (arr) => (arr || []).map((t) => (typeof t === "string" ? t : t.name));

      const levelMap = new Map();
      for (const [field, level] of Object.entries(FIELD_TO_LEVEL)) {
        for (const name of toNames(u[field])) {
          levelMap.set(name, level);
        }
      }
      this._initialLevelMap = new Map(levelMap);
      this.selectedLevels   = new Map(levelMap);
      this._autoUpdateParentTags();
    } catch (e) {
      console.error("[tsub] ошибка загрузки:", e);
    } finally {
      this.isLoading = false;
    }
  }

  buildGroups(rawGroups) {
    const configured = (this.siteSettings.tag_subscription_groups || "")
      .split("|").map((s) => s.trim()).filter(Boolean);
    if (!configured.length) return [];

    const byName = Object.fromEntries(rawGroups.map((g) => [g.name, g]));

    return configured
      .map((name) => byName[name])
      .filter((g) => g && (g.tags || []).length > 0)
      .map((g) => ({
        name:          g.name,
        tags:          g.tags.map((t) => ({ name: t.name })).sort((a, b) => a.name.localeCompare(b.name, "ru")),
        parentTagName: g.parent_tag?.[0]?.name || null,
      }));
  }

  // ─── Авто-выбор родительского тега ────────────────────────────────────────

  _autoUpdateParentTags() {
    const next = new Map(this.selectedLevels);
    let changed = false;

    for (const group of this.tagGroups) {
      if (!group.parentTagName) continue;
      const allSelected    = group.tags.every((t) => next.has(t.name));
      const parentSelected = next.has(group.parentTagName);

      if (allSelected && !parentSelected) {
        next.set(group.parentTagName, "watching_first_post");
        changed = true;
      } else if (!allSelected && parentSelected) {
        next.delete(group.parentTagName);
        changed = true;
      }
    }

    if (changed) this.selectedLevels = next;
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  @action isSelected(name) { return this.selectedLevels.has(name); }
  @action isExpanded(name) { return this.expandedGroups.has(name); }

  @action
  tagClass(name) {
    const level = this.selectedLevels.get(name);
    if (!level) return "";
    return level === "watching" ? "sel-2" : "sel-1";
  }

  @action
  sectionState(group) {
    const count = group.tags.filter((t) => this.selectedLevels.has(t.name)).length;
    if (count === 0) return "none";
    if (count === group.tags.length) return "all";
    return "some";
  }

  @action
  subTagSelectedCount(group) {
    return group.tags.filter((t) => this.selectedLevels.has(t.name)).length;
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
    const next    = new Map(this.selectedLevels);
    const current = next.get(name);
    if (!current)                          next.set(name, "watching_first_post");
    else if (current === "watching_first_post") next.set(name, "watching");
    else                                   next.delete(name);
    this.selectedLevels = next;
    this._autoUpdateParentTags();
  }

  @action
  toggleSection(group) {
    const next        = new Map(this.selectedLevels);
    const allSelected = group.tags.every((t) => next.has(t.name));
    if (allSelected) {
      group.tags.forEach((t) => next.delete(t.name));
    } else {
      group.tags.forEach((t) => { if (!next.has(t.name)) next.set(t.name, "watching_first_post"); });
    }
    this.selectedLevels = next;
    this._autoUpdateParentTags();
  }

  @action
  deselectAllInGroup(group) {
    const next = new Map(this.selectedLevels);
    group.tags.forEach((t) => next.delete(t.name));
    this.selectedLevels = next;
    this._autoUpdateParentTags();
  }

  // ─── Сохранение ───────────────────────────────────────────────────────────

  async _doSave() {
    try {
      const username  = this.args.outletArgs?.model?.username;
      const allManaged = new Set([
        ...this.tagGroups.flatMap((g) => g.tags.map((t) => t.name)),
        ...this.pinnedTags,
      ]);

      const tagLists = { watching_first_post_tags: [], watched_tags: [], tracked_tags: [] };

      // Управляемые выбранные теги → по уровню
      for (const [name, level] of this.selectedLevels) {
        if (!allManaged.has(name)) continue;
        (tagLists[LEVEL_TO_FIELD[level] || "watching_first_post_tags"]).push(name);
      }

      // Неуправляемые теги → в их оригинальные поля
      for (const [name, level] of this._initialLevelMap) {
        if (allManaged.has(name)) continue;
        (tagLists[LEVEL_TO_FIELD[level] || "watching_first_post_tags"]).push(name);
      }

      const params = new URLSearchParams();
      for (const [field, tags] of Object.entries(tagLists)) {
        params.set(field, tags.join(","));
      }
      params.set("muted_tags", "");

      await ajax(`/u/${username}.json`, {
        type: "PUT",
        contentType: "application/x-www-form-urlencoded; charset=UTF-8",
        data: params.toString(),
      });

      // Обновляем initial map
      const newMap = new Map();
      for (const [name, level] of this.selectedLevels) {
        if (allManaged.has(name)) newMap.set(name, level);
      }
      for (const [name, level] of this._initialLevelMap) {
        if (!allManaged.has(name)) newMap.set(name, level);
      }
      this._initialLevelMap = newMap;

    } catch (e) {
      console.error("[tsub] ошибка сохранения:", e);
    }
  }
}
