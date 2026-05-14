import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import icon from "discourse/helpers/d-icon";
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
      `Кликните по тегу чтобы указать уровень уведомления.<br>` +
      `Один клик ${sq(this._c1)}&hairsp;— уведомление о новых темах.<br>` +
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
      const allSelected  = group.tags.every((t) => next.has(t.name));
      const currentLevel = next.get(group.parentTagName);

      if (allSelected) {
        const targetLevel = group.tags.every((t) => next.get(t.name) === "watching")
          ? "watching"
          : "watching_first_post";
        if (currentLevel !== targetLevel) {
          next.set(group.parentTagName, targetLevel);
          changed = true;
        }
      } else if (currentLevel !== undefined) {
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
    if (group.parentTagName) {
      const parentLevel = this.selectedLevels.get(group.parentTagName);
      if (parentLevel === "watching") return "parent-sel-2";
      if (parentLevel === "watching_first_post") return "parent-sel-1";
    }
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
    const allWatching = allSelected && group.tags.every((t) => next.get(t.name) === "watching");

    if (allWatching) {
      group.tags.forEach((t) => next.delete(t.name));
    } else if (allSelected) {
      group.tags.forEach((t) => next.set(t.name, "watching"));
    } else {
      group.tags.forEach((t) => next.set(t.name, "watching_first_post"));
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
        ...this.tagGroups.filter((g) => g.parentTagName).map((g) => g.parentTagName),
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

  <template>
    {{! Inline styles — гарантируют применение даже если SCSS не подхватился }}
    <style>
    .tsub-root {
      max-width: 700px;
      margin-top: 1.5rem;
      padding-top: 1.25rem;
      border-top: 1px solid var(--primary-low);
    }
    .tsub-title {
      font-size: 1.05rem;
      font-weight: 700;
      margin-bottom: 0.4rem;
      color: var(--primary);
    }
    .tsub-help-link {
      display: inline-flex;
      align-items: center;
      gap: 0.3em;
      font-size: var(--font-down-1);
      color: var(--tertiary);
      margin-bottom: 0.5rem;
      text-decoration: none;
    }
    .tsub-help-link .d-icon {
      width: 0.9em;
      height: 0.9em;
    }
    .tsub-help-link:hover {
      text-decoration: underline;
    }
    .tsub-hint {
      color: var(--primary-medium);
      font-size: var(--font-down-1);
      margin-bottom: 1rem;
      line-height: 1.5;
    }
    .tsub-total {
      font-size: var(--font-down-1);
      color: var(--primary-medium);
      margin-bottom: 0.75rem;
    }
    .tsub-loading {
      display: flex;
      align-items: center;
      gap: 0.6rem;
      color: var(--primary-medium);
      padding: 1rem 0;
    }
    .tsub-spinner {
      width: 16px; height: 16px;
      border: 2px solid var(--primary-low);
      border-top-color: var(--tertiary);
      border-radius: 50%;
      animation: tsub-spin 0.7s linear infinite;
    }
    @keyframes tsub-spin { to { transform: rotate(360deg); } }

    .tsub-group {
      border: 2px solid var(--primary-low);
      border-radius: 0.3em;
      margin-bottom: 10px;
      overflow: hidden;
      transition: border-color 0.2s, box-shadow 0.2s;
    }
    .tsub-group.some {
      border-color: var(--tertiary-medium);
      box-shadow: 0 0 0 1px var(--tertiary-very-low);
    }
    .tsub-group.all {
      border-color: var(--tertiary);
      box-shadow: 0 0 6px 0 var(--tertiary-very-low);
    }
    .tsub-group.parent-sel-1 {
      border-color: var(--tsub-c1, #e5b000);
      box-shadow: 0 0 6px 0 var(--tsub-c1-bg, rgba(229,176,0,0.18));
    }
    .tsub-group.parent-sel-2 {
      border-color: var(--tsub-c2, #cc5500);
      box-shadow: 0 0 6px 0 var(--tsub-c2-bg, rgba(204,85,0,0.18));
    }

    .tsub-pinned-title {
      flex: 1;
      font-weight: 600;
      font-size: var(--font-0);
      color: var(--primary);
      padding: 0.5em 0.65em;
    }
    .tsub-group-header {
      display: flex;
      align-items: center;
      gap: 0;
      background: var(--primary-very-low);
    }
    .tsub-group-name-btn {
      flex: 1;
      display: flex;
      align-items: baseline;
      padding: 0.5em 0.65em;
      background: none;
      border: none;
      cursor: pointer;
      text-align: left;
    }
    .tsub-group-name-btn:hover {
      background: transparent;
    }
    .tsub-group-header:has(.tsub-group-name-btn:hover) {
      background: var(--primary-low);
    }
    .tsub-group-name {
      font-weight: 600;
      font-size: var(--font-0);
      color: var(--primary);
    }
    .tsub-group-parent {
      font-size: var(--font-down-2);
      font-weight: 400;
      color: var(--primary-medium);
      margin-left: 0.4em;
    }
    .tsub-group-count {
      font-size: var(--font-down-2);
      color: var(--primary-medium);
      background: var(--primary-low);
      padding: 2px 8px;
      border-radius: 10px;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
      flex-shrink: 0;
      margin-right: 0.5em;
      transition: background 0.1s, color 0.1s;
    }
    .tsub-group-header:has(.tsub-group-name-btn:hover) .tsub-group-count {
      background: var(--primary-medium);
      color: var(--secondary);
    }
    .tsub-expand-btn {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 2.75rem;
      align-self: stretch;
      flex-shrink: 0;
      padding: 0;
      background: none;
      border: none;
      border-left: 1px solid var(--primary-medium);
      cursor: pointer;
      color: var(--primary-high);
      transition: background 0.1s, color 0.1s;
    }
    .tsub-expand-btn:hover {
      background: var(--primary-low);
      color: var(--tertiary);
    }
    .tsub-chevron {
      width: 1.25em;
      height: 1.25em;
      display: block;
    }

    .tsub-group-body {
      padding: 0.6rem 0.75rem 0.75rem;
      border-top: 1px solid var(--primary-low);
    }
    .tsub-bulk {
      display: flex;
      gap: 0.4rem;
      margin-bottom: 0.6rem;
    }
    .tsub-bulk-btn {
      padding: 0.25em 0.65em;
      font-size: var(--font-down-2);
      border: 1px solid var(--primary-low);
      border-radius: 0.3em;
      background: none;
      cursor: pointer;
      color: var(--primary-medium);
      transition: background 0.1s, color 0.1s;
    }
    .tsub-bulk-btn:hover {
      background: var(--primary-low);
      color: var(--primary);
    }
    .tsub-tags-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(185px, 1fr));
      gap: 0.35rem;
    }
    .tsub-tag {
      display: flex;
      align-items: flex-start;
      gap: 0.4rem;
      padding: 0.3rem 0.5rem;
      border-radius: 0.3em;
      cursor: pointer;
      border: 1px solid transparent;
      font-size: var(--font-down-1);
      line-height: 1.4;
      transition: background 0.1s, border-color 0.1s;
      user-select: none;
    }
    .tsub-tag:hover {
      background: var(--primary-very-low);
    }
    .tsub-tag.sel-1 {
      background: var(--tsub-c1-bg, rgba(229,176,0,0.18));
      border-color: var(--tsub-c1-bd, rgba(229,176,0,0.5));
    }
    .tsub-tag.sel-2 {
      background: var(--tsub-c2-bg, rgba(204,85,0,0.18));
      border-color: var(--tsub-c2-bd, rgba(204,85,0,0.5));
    }
    .tsub-tag-dot {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      border: 2px solid var(--primary-low);
      flex-shrink: 0;
      margin-top: 2px;
      transition: background 0.15s, border-color 0.15s;
    }
    .tsub-tag.sel-1 .tsub-tag-dot {
      background: var(--tsub-c1, #e5b000);
      border-color: var(--tsub-c1, #e5b000);
    }
    .tsub-tag.sel-2 .tsub-tag-dot {
      background: var(--tsub-c2, #cc5500);
      border-color: var(--tsub-c2, #cc5500);
    }
    </style>

    {{#if this.siteEnabled}}
    <div class="tsub-root" style={{this.rootStyle}}>
      <h3 class="tsub-title">Подписки на теги</h3>

      {{#if this.helpTopicUrl}}
        <a class="tsub-help-link" href={{this.helpTopicUrl}} target="_blank" rel="noopener noreferrer">
          {{icon "circle-info"}} {{this.helpLinkLabel}} →
        </a>
      {{/if}}
      <p class="tsub-hint">{{this.hintHtml}}</p>

      {{#if this.isLoading}}
        <div class="tsub-loading">
          <div class="tsub-spinner"></div>
          Загрузка…
        </div>

      {{else if this.tagGroups.length}}

        <div class="tsub-total">
          Выбрано: <strong>{{this.totalSelected}}</strong>
        </div>

        {{#if this.pinnedTags.length}}
          <div class="tsub-group {{this.pinnedSectionState}}">
            <div class="tsub-group-header">
              <span class="tsub-pinned-title">Иные теги</span>
              <span class="tsub-group-count">
                {{this.pinnedSelectedCount}}/{{this.pinnedTags.length}}
              </span>
            </div>
            <div class="tsub-group-body">
              <div class="tsub-tags-grid">
                {{#each this.pinnedTags as |tagName|}}
                  <div class="tsub-tag {{this.tagClass tagName}}"
                       role="button"
                       tabindex="0"
                       {{on "click" (fn this.toggleTag tagName)}}>
                    <span class="tsub-tag-dot"></span>
                    <span>{{this.displayName tagName}}</span>
                  </div>
                {{/each}}
              </div>
            </div>
          </div>
        {{/if}}

        {{#each this.tagGroups as |group|}}
          <div class="tsub-group {{this.sectionState group}}">

            <div class="tsub-group-header">
              <button
                type="button"
                class="tsub-group-name-btn"
                title="Выбрать/снять все теги раздела"
                {{on "click" (fn this.toggleSection group)}}
              >
                <span class="tsub-group-name">{{this.displayName group.name}}</span>
                {{#if group.parentTagName}}
                  <span class="tsub-group-parent">({{this.displayName group.parentTagName}})</span>
                {{/if}}
              </button>

              <span class="tsub-group-count">
                {{this.subTagSelectedCount group}}/{{group.tags.length}}
              </span>

              <button
                type="button"
                class="tsub-expand-btn"
                title="Развернуть/свернуть"
                {{on "click" (fn this.toggleExpanded group.name)}}
              >
                {{#if (this.isExpanded group.name)}}
                  <svg class="tsub-chevron" width="20" height="20" viewBox="0 0 20 20" fill="currentColor" xmlns="http://www.w3.org/2000/svg">
                    <path fill-rule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 11.168l3.71-3.938a.75.75 0 111.08 1.04l-4.25 4.5a.75.75 0 01-1.08 0l-4.25-4.5a.75.75 0 01.02-1.06z" clip-rule="evenodd"/>
                  </svg>
                {{else}}
                  <svg class="tsub-chevron" width="20" height="20" viewBox="0 0 20 20" fill="currentColor" xmlns="http://www.w3.org/2000/svg">
                    <path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z" clip-rule="evenodd"/>
                  </svg>
                {{/if}}
              </button>
            </div>

            {{#if (this.isExpanded group.name)}}
              <div class="tsub-group-body">
                <div class="tsub-bulk">
                  <button type="button" class="tsub-bulk-btn"
                    {{on "click" (fn this.deselectAllInGroup group)}}>
                    Сбросить
                  </button>
                </div>
                <div class="tsub-tags-grid">
                  {{#each group.tags as |tag|}}
                    <div class="tsub-tag {{this.tagClass tag.name}}"
                         role="button"
                         tabindex="0"
                         {{on "click" (fn this.toggleTag tag.name)}}>
                      <span class="tsub-tag-dot"></span>
                      <span>{{this.displayName tag.name}}</span>
                    </div>
                  {{/each}}
                </div>
              </div>
            {{/if}}

          </div>
        {{/each}}

      {{else}}
        <p style="color: var(--danger)">Группы тегов не настроены или недоступны. Проверьте настройки плагина.</p>
      {{/if}}


    </div>
    {{/if}}{{! siteEnabled }}
  </template>
}
