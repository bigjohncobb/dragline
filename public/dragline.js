/**
 * Dragline Entity Intelligence Platform — Client-side behaviours
 * Self-contained vanilla JS. No external dependencies.
 */

(function () {
  'use strict';

  /* ── 1. Dark / Light Mode Toggle ─────────────────────────────────────── */

  const THEME_KEY = 'dragline-theme';
  const html = document.documentElement;

  function getStoredTheme() {
    try {
      return localStorage.getItem(THEME_KEY);
    } catch (e) {
      return null;
    }
  }

  function setStoredTheme(theme) {
    try {
      if (theme) {
        localStorage.setItem(THEME_KEY, theme);
      } else {
        localStorage.removeItem(THEME_KEY);
      }
    } catch (e) {
      // localStorage may be unavailable
    }
  }

  function applyTheme(theme) {
    if (theme === 'light') {
      html.setAttribute('data-theme', 'light');
    } else if (theme === 'dark') {
      html.setAttribute('data-theme', 'dark');
    } else {
      html.removeAttribute('data-theme');
    }
    updateThemeToggleIcon();
  }

  function getEffectiveTheme() {
    const stored = getStoredTheme();
    if (stored) return stored;
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
      return 'light';
    }
    return 'dark';
  }

  function toggleTheme() {
    const current = getEffectiveTheme();
    const next = current === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    setStoredTheme(next);
  }

  function updateThemeToggleIcon() {
    const btn = document.querySelector('.theme-toggle');
    if (!btn) return;
    const isLight = getEffectiveTheme() === 'light';
    // Sun icon for dark mode (click to go light), moon icon for light mode
    btn.innerHTML = isLight
      ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>'
      : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>';
    btn.setAttribute('aria-label', isLight ? 'Switch to dark mode' : 'Switch to light mode');
    btn.setAttribute('title', isLight ? 'Switch to dark mode' : 'Switch to light mode');
  }

  function initTheme() {
    const stored = getStoredTheme();
    if (stored) {
      applyTheme(stored);
    } else {
      applyTheme(null);
    }
  }

  // Listen for toggle clicks
  document.addEventListener('click', function (e) {
    const btn = e.target.closest('.theme-toggle');
    if (btn) {
      e.preventDefault();
      toggleTheme();
    }
  });

  // Listen for OS theme changes when no manual override
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', function (e) {
      if (!getStoredTheme()) {
        applyTheme(null);
      }
    });
  }

  /* ── 2. Mark-as-Seen (Individual) ────────────────────────────────────── */

  function getCsrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : '';
  }

  document.addEventListener('click', function (e) {
    const btn = e.target.closest('[data-action="mark-seen"]');
    if (!btn) return;

    e.preventDefault();
    const changeId = btn.dataset.changeId;
    if (!changeId) return;

    const eventEl = btn.closest('.change-event');

    fetch('/changes/' + encodeURIComponent(changeId) + '/seen', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': getCsrfToken(),
      },
      credentials: 'same-origin',
      body: '{}',
    })
      .then(function (response) {
        if (!response.ok) throw new Error('Request failed');
        if (eventEl) {
          eventEl.classList.add('seen');
        }
        btn.disabled = true;
        btn.textContent = 'Seen';
      })
      .catch(function (err) {
        console.error('Failed to mark as seen:', err);
      });
  });

  /* ── 3. Mark-all-Seen ────────────────────────────────────────────────── */

  document.addEventListener('click', function (e) {
    const btn = e.target.closest('[data-action="mark-all-seen"]');
    if (!btn) return;

    e.preventDefault();

    fetch('/changes/seen-all', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': getCsrfToken(),
      },
      credentials: 'same-origin',
      body: '{}',
    })
      .then(function (response) {
        if (!response.ok) throw new Error('Request failed');
        window.location.reload();
      })
      .catch(function (err) {
        console.error('Failed to mark all as seen:', err);
      });
  });

  /* ── 4. API Key Copy Button ──────────────────────────────────────────── */

  document.addEventListener('click', function (e) {
    const btn = e.target.closest('.key-copy-btn');
    if (!btn) return;

    const keyBox = btn.closest('.one-time-key');
    if (!keyBox) return;

    const keyValue = keyBox.querySelector('.key-value');
    const textToCopy = keyValue ? keyValue.textContent.trim() : '';

    if (!textToCopy) return;

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(textToCopy)
        .then(function () {
          const originalText = btn.textContent;
          btn.textContent = 'Copied';
          btn.classList.add('copied');
          setTimeout(function () {
            btn.textContent = originalText;
            btn.classList.remove('copied');
          }, 2000);
        })
        .catch(function (err) {
          console.error('Clipboard write failed:', err);
          fallbackCopy(textToCopy, btn);
        });
    } else {
      fallbackCopy(textToCopy, btn);
    }
  });

  function fallbackCopy(text, btn) {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand('copy');
      const originalText = btn.textContent;
      btn.textContent = 'Copied';
      btn.classList.add('copied');
      setTimeout(function () {
        btn.textContent = originalText;
        btn.classList.remove('copied');
      }, 2000);
    } catch (err) {
      console.error('Fallback copy failed:', err);
    }
    document.body.removeChild(textarea);
  }

  /* ── 5. Delete Confirm ───────────────────────────────────────────────── */

  document.addEventListener('click', function (e) {
    const btn = e.target.closest('[data-confirm]');
    if (!btn) return;

    const message = btn.dataset.confirm;
    if (!message) return;

    if (!confirm(message)) {
      e.preventDefault();
      e.stopPropagation();
    }
  });

  /* ── 6. Dossier Sections (Persist Open State) ────────────────────────── */

  const DOSSIER_KEY = 'dragline-dossier-open';

  function getOpenDossiers() {
    try {
      const raw = localStorage.getItem(DOSSIER_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function saveOpenDossiers(ids) {
    try {
      localStorage.setItem(DOSSIER_KEY, JSON.stringify(ids));
    } catch (e) {
      // ignore
    }
  }

  function initDossierSections() {
    const dossiers = document.querySelectorAll('.dossier-section');
    const openIds = getOpenDossiers();

    dossiers.forEach(function (el) {
      const id = el.id;
      if (id && openIds.includes(id)) {
        el.open = true;
      }
    });

    document.addEventListener('toggle', function (e) {
      const el = e.target;
      if (!el.classList.contains('dossier-section')) return;
      const id = el.id;
      if (!id) return;

      let openIds = getOpenDossiers();
      if (el.open) {
        if (!openIds.includes(id)) {
          openIds.push(id);
        }
      } else {
        openIds = openIds.filter(function (x) { return x !== id; });
      }
      saveOpenDossiers(openIds);
    }, true);
  }

  /* ── 7. Live Job Status Poller ───────────────────────────────────────── */

  var TASK_LABELS = {
    crawl_static:     'Crawl',
    discover:         'Discovery',
    forge_sync:       'Forge sync',
    synthesise:       'Generate dossier',
    embed:            'Embed',
    ingest_pdf:       'Ingest PDF',
    doc_intelligence: 'Extract intelligence',
  };

  function htmlEsc(str) {
    return String(str)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function JobPoller(jobs) {
    this.jobs  = jobs;
    this.timer = null;
    this.panel = null;
    this.list  = null;
  }

  JobPoller.prototype.start = function () {
    this.panel = document.getElementById('job-status-panel');
    this.list  = document.getElementById('job-panel-list');
    if (!this.panel || !this.list) return;

    var self = this;
    this.jobs.forEach(function (job) { self.renderItem(job, 'inactive', null); });
    this.panel.hidden = false;

    this.panel.addEventListener('click', function (e) {
      if (e.target.closest('.job-panel-close')) {
        self.panel.hidden = true;
        clearTimeout(self.timer);
      }
    });

    this.poll();
  };

  JobPoller.prototype.poll = function () {
    var self = this;
    var ids = this.jobs.map(function (j) { return j.id; }).join(',');
    if (!ids) return;

    fetch('/job-status?ids=' + encodeURIComponent(ids), { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
      .then(function (results) { self.handleResults(results); })
      .catch(function () { self.schedule(false); });
  };

  JobPoller.prototype.handleResults = function (results) {
    var self = this;
    var infoById = {};
    results.forEach(function (r) { infoById[r.id] = r; });

    var anyRunning = false;
    this.jobs = this.jobs.filter(function (job) {
      var info = infoById[job.id];
      if (!info) { anyRunning = true; return true; }

      self.renderItem(job, info.state, info.error);

      if (info.state === 'inactive' || info.state === 'active') {
        anyRunning = true;
        return true;
      }
      if (info.state === 'finished') {
        setTimeout(function () {
          var el = document.getElementById('job-item-' + job.id);
          if (el) el.remove();
          self.maybeHide();
        }, 4000);
        return false;
      }
      return true;  // keep failed jobs visible
    });

    this.schedule(anyRunning);
  };

  JobPoller.prototype.schedule = function (fast) {
    var self = this;
    clearTimeout(this.timer);
    if (!this.jobs.length) return;
    this.timer = setTimeout(function () { self.poll(); }, fast ? 3000 : 10000);
  };

  JobPoller.prototype.renderItem = function (job, state, error) {
    var elId = 'job-item-' + job.id;
    var el   = document.getElementById(elId);
    if (!el) {
      el = document.createElement('li');
      el.id = elId;
      this.list.appendChild(el);
    }
    var icon  = state === 'finished' ? '✓' : state === 'failed' ? '✗' : state === 'active' ? '⚙' : '⏳';
    var label = job.label || TASK_LABELS[job.task] || job.task;
    el.className = 'job-panel-item job-state-' + state;
    el.innerHTML = '<span class="job-icon">' + icon + '</span>'
                 + '<span class="job-label">' + htmlEsc(label) + '</span>'
                 + (error ? '<span class="job-error">' + htmlEsc(String(error)) + '</span>' : '');
  };

  JobPoller.prototype.maybeHide = function () {
    if (this.list && this.list.children.length === 0) {
      this.panel.hidden = true;
    }
  };

  function initJobPoller() {
    var meta = document.querySelector('meta[name="pending-jobs"]');
    if (!meta || !meta.content) return;
    var jobs;
    try { jobs = JSON.parse(meta.content); } catch (e) { return; }
    if (!jobs || !jobs.length) return;
    new JobPoller(jobs).start();
  }

  function init() {
    initTheme();
    initDossierSections();
    initJobPoller();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
