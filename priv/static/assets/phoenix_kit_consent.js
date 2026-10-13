/**
 * PhoenixKit Cookie Consent Manager
 *
 * A lightweight, GDPR/CCPA compliant cookie consent solution with:
 * - Automatic DOM injection (no layout changes required)
 * - localStorage persistence with cross-tab sync
 * - Google Consent Mode v2 integration
 * - Script blocking by category
 * - Phoenix LiveView hook integration
 * - A server-side record of each decision (signed cookie + audit log)
 *
 * @version 2.1.0
 * @license MIT
 */
(function() {
  "use strict";

  // Prevent double initialization — of this script. PhoenixKit's own bundle
  // (`phoenix_kit.js`) carries an older copy of this manager that loads first
  // on most hosts and knows nothing about the server's record; left in charge,
  // no decision would ever be reported. So an older copy is retired rather
  // than deferred to: it is marked initialized (its hook and its config fetch
  // both check that flag and do nothing), and its hook object — the one the
  // host's LiveSocket may already hold — is given this script's callbacks
  // further down.
  var previous = window.PhoenixKitConsent;
  if (previous && previous.reportsDecisions) return;
  if (previous) {
    previous.initialized = true;
    // The older copy injects the widget itself on DOMContentLoaded when the
    // page has none, unless this flag says the Legal module is absent. This
    // script does that job instead (see `autoInit`), so the older copy is
    // told to stand down. If it has already started, both inject and this
    // one still answers the buttons — untidy, never wrong.
    window.PHOENIX_KIT_CONSENT_AVAILABLE = false;
  }

  // =====================================================
  // CONSTANTS
  // =====================================================

  const STORAGE_KEY = "pk_consent";
  const VERSION_KEY = "pk_consent_version";
  const REVOKE_PENDING_KEY = "pk_consent_revoke_pending";
  // sessionStorage; SYNCED_AT_KEY is its localStorage stand-in.
  const SYNCED_KEY = "pk_consent_synced";
  const SYNCED_AT_KEY = "pk_consent_synced_at";
  const CATEGORIES = ["necessary", "analytics", "marketing", "preferences"];

  // Get PhoenixKit URL prefix from global variable set by PhoenixKit
  function getConfigEndpoint() {
    const prefix = window.PHOENIX_KIT_PREFIX || "/phoenix_kit";
    // Handle case when prefix is "/" to avoid double slash (//api/...)
    if (prefix === "/") {
      return "/api/consent-config";
    }
    return prefix + "/api/consent-config";
  }
  const OPT_IN_FRAMEWORKS = ["gdpr", "uk_gdpr", "lgpd", "pipeda"];
  const DEFAULT_COOKIE_NAME = "pk_consent";
  const DEFAULT_COOKIE_DAYS = 180;

  // =====================================================
  // MODULE STATE
  // =====================================================

  var PhoenixKitConsent = {
    // Marks a copy that reports each decision to the consent endpoint.
    reportsDecisions: true,
    initialized: false,
    config: {
      frameworks: [],
      policyVersion: "1.0",
      googleConsentMode: false,
      iconPosition: "bottom-right",
      showIcon: false,
      cookiePolicyUrl: "/legal/cookie-policy",
      privacyPolicyUrl: "/legal/privacy-policy",
      consentEndpoint: null,
      cookieName: DEFAULT_COOKIE_NAME,
      cookieDays: DEFAULT_COOKIE_DAYS,
      reloadOnWithdrawal: true
    },
    consent: null,
    elements: {
      root: null,
      icon: null,
      banner: null,
      modal: null
    }
  };

  // =====================================================
  // UTILITIES
  // =====================================================

  function log(message, data) {
    if (typeof console !== "undefined" && console.debug) {
      console.debug("[PhoenixKitConsent] " + message, data || "");
    }
  }

  // Escape values destined for an HTML attribute (e.g. href="..."). Prevents
  // user-controlled URLs (admin-defined post slugs) from breaking out of the
  // attribute or injecting new tags.
  function escapeAttr(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  // Escape values destined for HTML text content. Defense-in-depth for
  // gettext-derived translation strings concatenated into innerHTML.
  function escapeText(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function t(key, fallback) {
    var translations = PhoenixKitConsent.config.translations || {};
    return translations[key] || fallback;
  }

  function tc(categoryId, field, fallback) {
    var cats = (PhoenixKitConsent.config.translations || {}).categories || {};
    return (cats[categoryId] || {})[field] || fallback;
  }

  function isOptInMode() {
    var frameworks = PhoenixKitConsent.config.frameworks;
    for (var i = 0; i < OPT_IN_FRAMEWORKS.length; i++) {
      if (frameworks.indexOf(OPT_IN_FRAMEWORKS[i]) !== -1) {
        return true;
      }
    }
    return false;
  }

  // =====================================================
  // STORAGE
  // =====================================================

  function loadConsent() {
    try {
      var stored = localStorage.getItem(STORAGE_KEY);
      if (stored) {
        return JSON.parse(stored);
      }
    } catch (e) {
      log("Could not load consent", e);
    }
    return null;
  }

  function saveConsent(consent) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(consent));
      localStorage.setItem(VERSION_KEY, PhoenixKitConsent.config.policyVersion);
      log("Consent saved", consent);
    } catch (e) {
      log("Could not save consent", e);
    }
  }

  function getStoredVersion() {
    try {
      return localStorage.getItem(VERSION_KEY);
    } catch (e) {
      return null;
    }
  }

  function shouldShowBanner() {
    var stored = loadConsent();
    if (isExpired(stored)) stored = null;
    var storedVersion = getStoredVersion();
    var currentVersion = PhoenixKitConsent.config.policyVersion;
    var consentMode = PhoenixKitConsent.config.consentMode;

    // In notice mode: only show once (don't re-show on version change)
    if (consentMode === "notice") {
      return !stored;
    }

    // In strict mode: re-show if no consent or version changed
    if (!stored || storedVersion !== currentVersion) {
      return true;
    }
    return false;
  }

  // =====================================================
  // SERVER RECORD
  // =====================================================
  //
  // localStorage is this browser's copy of the decision. The server cannot
  // read it, so each decision is also reported to the consent endpoint, which
  // writes the audit record and answers with a signed first-party cookie —
  // the copy server-side collection obeys.

  // Whether this browser has already compared its decision with the
  // server's in this session. sessionStorage when there is one; otherwise a
  // timestamp in localStorage, good for a day.
  function reconciledAlready() {
    try {
      if (window.sessionStorage) return sessionStorage.getItem(SYNCED_KEY) === "1";
    } catch (e) {
      // Fall through to localStorage.
    }
    try {
      var at = parseInt(localStorage.getItem(SYNCED_AT_KEY), 10);
      return !isNaN(at) && Date.now() - at < 86400000;
    } catch (e) {
      // Nowhere to remember it: say it was done, rather than repeat it on
      // every page.
      return true;
    }
  }

  function setReconciled(done) {
    try {
      if (window.sessionStorage) {
        if (done) {
          sessionStorage.setItem(SYNCED_KEY, "1");
        } else {
          sessionStorage.removeItem(SYNCED_KEY);
        }
        return;
      }
    } catch (e) {
      // Fall through to localStorage.
    }
    try {
      if (done) {
        localStorage.setItem(SYNCED_AT_KEY, String(Date.now()));
      } else {
        localStorage.removeItem(SYNCED_AT_KEY);
      }
    } catch (e) {
      log("Could not remember the reconciliation", e);
    }
  }

  function sameCategories(server, consent) {
    if (!server || typeof server !== "object") return false;
    for (var i = 0; i < CATEGORIES.length; i++) {
      var category = CATEGORIES[i];
      if (category !== "necessary" && !!server[category] !== !!consent[category]) return false;
    }
    return true;
  }

  // What the server holds for this browser: resolves to
  // `{ status: <HTTP status>, body: <the JSON, when the status is 200> }`,
  // rejects when the server could not be reached.
  function fetchServerConsent() {
    return fetch(PhoenixKitConsent.config.consentEndpoint, {
      method: "GET",
      credentials: "same-origin",
      headers: { "accept": "application/json" }
    }).then(function(response) {
      if (!response.ok) return { status: response.status, body: null };
      return response.json().then(function(body) {
        return { status: response.status, body: body };
      });
    });
  }

  // When a local decision was made, in the server's unit (unix seconds);
  // 0 when it does not say.
  function decidedAt(consent) {
    var at = consent && consent.timestamp ? Date.parse(consent.timestamp) : NaN;
    return isNaN(at) ? 0 : Math.floor(at / 1000);
  }

  // The server's decision in the shape this script keeps its own.
  function fromServer(server) {
    var categories = server.consent || {};
    return {
      necessary: true,
      analytics: !!categories.analytics,
      marketing: !!categories.marketing,
      preferences: !!categories.preferences,
      timestamp: new Date(server.decided_at * 1000).toISOString()
    };
  }

  // Takes the server's decision as this browser's: it was made after the
  // one kept here — on another port or scheme of this host, which shares the
  // cookie but not localStorage, or by the site through the endpoint.
  function adoptServerConsent(server) {
    var before = PhoenixKitConsent.consent;
    var consent = fromServer(server);

    PhoenixKitConsent.consent = consent;
    saveConsent(consent);
    applyConsent(consent);
    updateUI();
    log("Adopted the server's newer decision", consent);

    // As when the visitor takes a consent back here: what already ran on
    // this page ran under the old choice.
    if (PhoenixKitConsent.config.reloadOnWithdrawal && withdrew(before, consent)) {
      window.location.reload();
    }
  }

  // Asks the server what it holds for this browser and settles any
  // difference — the newer copy wins, in either direction.
  //
  //   * The server holds nothing, or a decision for another policy version:
  //     it is handed this browser's (made before the server kept any, or a
  //     report — a re-consent to a new policy, say — that never arrived).
  //   * The same version, other choices: whichever was made later stands.
  //     A withdrawal whose report failed is sent again, where it would
  //     otherwise leave the old cookie answering "granted" for months; a
  //     decision the server took later is adopted here instead of being
  //     overwritten with the stale local one.
  //
  // The server is asked, rather than the cookie looked at, because a cookie
  // can be there and mean nothing to the server: signed with a key since
  // rotated, or set by another application on the same host.
  //
  // Once per session — unless it could not be done (the server did not
  // answer, or did not take the report), in which case the next page tries
  // again. A browser that refuses the cookie would otherwise report on
  // every page, and the server, seeing no cookie, would log each report as
  // a new visitor's decision.
  function reconcileWithServer(consent) {
    var endpoint = PhoenixKitConsent.config.consentEndpoint;
    if (!endpoint || typeof fetch !== "function") return;
    if (reconciledAlready()) return;
    setReconciled(true);

    function handOver() {
      return reportConsent(consent, "sync").then(function(recorded) {
        if (!recorded) setReconciled(false);
      });
    }

    fetchServerConsent().then(function(answer) {
      if (answer.status !== 200) throw new Error("Consent endpoint returned " + answer.status);
      var server = answer.body || {};

      if (!server.decided || server.version !== PhoenixKitConsent.config.policyVersion) {
        return handOver();
      }
      if (sameCategories(server.consent, consent)) return;
      if (server.decided_at > decidedAt(consent)) return adoptServerConsent(server);
      return handOver();
    }).catch(function(err) {
      setReconciled(false);
      log("Could not compare consent with the server", err);
    });
  }

  // When the revocation still waiting to be delivered was made (unix
  // milliseconds), or null when none is waiting.
  function revokePendingSince() {
    try {
      var value = localStorage.getItem(REVOKE_PENDING_KEY);
      if (value === null) return null;
      var at = parseInt(value, 10);
      // A flag with no usable time in it is taken as made just now, so that
      // it is delivered rather than dropped.
      return isNaN(at) || at < 1000000000000 ? Date.now() : at;
    } catch (e) {
      return null;
    }
  }

  function setRevokePending(pending) {
    try {
      if (pending) {
        localStorage.setItem(REVOKE_PENDING_KEY, String(Date.now()));
      } else {
        localStorage.removeItem(REVOKE_PENDING_KEY);
      }
    } catch (e) {
      log("Could not update the pending revocation", e);
    }
  }

  // The DELETE that takes the server's copy back. The flag is set before it
  // — with the time, so a later page can tell what the revocation covers —
  // and cleared only when the server answers, so a request that never
  // arrived (offline, a closed tab) is sent again on the next page.
  function revokeOnServer() {
    setRevokePending(true);
    return deliverRevoke();
  }

  function deliverRevoke() {
    return forgetServerConsent().then(function(forgotten) {
      if (forgotten) setRevokePending(false);
      return forgotten;
    });
  }

  // A revocation left over from an earlier page. It takes back what the
  // server held when it was made, and nothing since: a decision the server
  // recorded later (in another tab, on another port of this host) is not
  // this revocation's to delete, so the server is asked first.
  function retryRevoke(since) {
    var endpoint = PhoenixKitConsent.config.consentEndpoint;
    if (!endpoint || typeof fetch !== "function") {
      // Nowhere to deliver it, now or later.
      setRevokePending(false);
      return;
    }

    fetchServerConsent().then(function(answer) {
      // 404: the banner is switched off, and the endpoint with it.
      if (answer.status === 404) return setRevokePending(false);
      if (answer.status !== 200) return;

      var server = answer.body || {};
      if (!server.decided || server.decided_at * 1000 > since) {
        // Nothing left to take back, or nothing of this revocation's.
        setRevokePending(false);
      } else {
        deliverRevoke();
      }
    }).catch(function(err) {
      log("Could not deliver the pending revocation", err);
    });
  }

  // A decision older than the cookie's lifetime has expired on the server;
  // it expires here too, so the visitor is asked again rather than held to
  // a choice nobody can show any more.
  function isExpired(consent) {
    if (!consent || !consent.timestamp) return false;
    var days = PhoenixKitConsent.config.cookieDays || DEFAULT_COOKIE_DAYS;
    var decided = Date.parse(consent.timestamp);
    if (isNaN(decided)) return false;
    return Date.now() - decided > days * 86400000;
  }

  function withdrew(before, after) {
    if (!before) return false;
    for (var i = 0; i < CATEGORIES.length; i++) {
      var category = CATEGORIES[i];
      if (category !== "necessary" && before[category] && !after[category]) return true;
    }
    return false;
  }

  function reportConsent(consent, source) {
    var endpoint = PhoenixKitConsent.config.consentEndpoint;
    if (!endpoint || typeof fetch !== "function") return Promise.resolve(false);

    return fetch(endpoint, {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { "content-type": "application/json", "accept": "application/json" },
      body: JSON.stringify({
        consent: {
          analytics: !!consent.analytics,
          marketing: !!consent.marketing,
          preferences: !!consent.preferences
        },
        source: source
      })
    }).then(function(response) {
      if (!response.ok) log("Consent endpoint returned " + response.status);
      return response.ok;
    }).catch(function(err) {
      log("Could not report consent", err);
      return false;
    });
  }

  // Resolves to whether the server's copy is gone. With no endpoint there is
  // no copy, and a 404 means the banner — and the endpoint with it — is
  // switched off: both are "done", not something to retry on every page.
  function forgetServerConsent() {
    var endpoint = PhoenixKitConsent.config.consentEndpoint;
    if (!endpoint || typeof fetch !== "function") return Promise.resolve(true);

    return fetch(endpoint, {
      method: "DELETE",
      credentials: "same-origin",
      keepalive: true,
      headers: { "accept": "application/json" }
    }).then(function(response) {
      return response.ok || response.status === 404;
    }).catch(function(err) {
      log("Could not forget consent", err);
      return false;
    });
  }

  // On load: an expired decision is dropped, a live one is applied — and
  // compared with the server's copy (`reconcileWithServer`), unless the
  // policy has changed since, in which case the visitor is about to be
  // asked again anyway. A revocation the server never heard of is sent
  // again first.
  function restoreConsent() {
    var stored = loadConsent();

    var revokedAt = revokePendingSince();
    if (revokedAt !== null) {
      if (stored) {
        // A decision made after the revocation replaces it.
        setRevokePending(false);
      } else {
        retryRevoke(revokedAt);
      }
    }

    if (isExpired(stored)) {
      try {
        localStorage.removeItem(STORAGE_KEY);
        localStorage.removeItem(VERSION_KEY);
      } catch (e) {
        log("Could not drop expired consent", e);
      }
      stored = null;
    }

    if (stored) {
      PhoenixKitConsent.consent = stored;
      applyConsent(stored);
      if (getStoredVersion() === PhoenixKitConsent.config.policyVersion) {
        reconcileWithServer(stored);
      }
    } else if (isOptInMode() && PhoenixKitConsent.config.consentMode === "strict") {
      // Only block scripts in strict mode
      blockScripts();
    }
  }

  // One path for every decision: store, apply, report — then, once the
  // server holds it, tell the page (`phx:consent-recorded`) and reload if
  // something was taken back, since a script that already ran cannot be
  // un-run and a page already loaded was served under the old choice.
  function decide(consent, source) {
    var before = PhoenixKitConsent.consent;
    var reload = PhoenixKitConsent.config.reloadOnWithdrawal && withdrew(before, consent);

    PhoenixKitConsent.consent = consent;
    saveConsent(consent);
    // A new decision replaces a revocation still waiting to be delivered.
    setRevokePending(false);
    applyConsent(consent);

    reportConsent(consent, source).then(function(recorded) {
      // A report that did not arrive is made up for on the next page.
      if (!recorded) setReconciled(false);
      window.dispatchEvent(new CustomEvent("phx:consent-recorded", {
        detail: { consent: consent, recorded: recorded }
      }));
      if (reload) window.location.reload();
    });
  }

  // =====================================================
  // CROSS-TAB SYNC
  // =====================================================

  function setupCrossTabSync() {
    window.addEventListener("storage", function(e) {
      // Removed in another tab — the key itself, or all of storage
      // (`e.key` is null then): the visitor took their consent back there,
      // and this tab must stop acting on the old one. Applying a refusal of
      // everything is what tells Google's consent mode and the page's own
      // listeners (`phx:consent-updated`); forgetting it in memory alone
      // would leave them on the old answer.
      if (e.key === null || (e.key === STORAGE_KEY && e.newValue === null)) {
        PhoenixKitConsent.consent = null;
        applyConsent({ necessary: true, analytics: false, marketing: false, preferences: false });
        updateUI();
        log("Cross-tab sync: consent revoked");
        return;
      }

      if (e.key !== STORAGE_KEY) return;

      try {
        var newConsent = JSON.parse(e.newValue);
        PhoenixKitConsent.consent = newConsent;
        applyConsent(newConsent);
        updateUI();
        log("Cross-tab sync: consent updated");
      } catch (err) {
        log("Cross-tab sync error", err);
      }
    });
  }

  // =====================================================
  // GOOGLE CONSENT MODE V2
  // =====================================================

  function initGoogleConsentMode() {
    if (!PhoenixKitConsent.config.googleConsentMode) return;

    window.dataLayer = window.dataLayer || [];
    function gtag() { window.dataLayer.push(arguments); }

    gtag("consent", "default", {
      "ad_storage": "denied",
      "analytics_storage": "denied",
      "ad_user_data": "denied",
      "ad_personalization": "denied",
      "personalization_storage": "denied",
      "functionality_storage": "granted",
      "security_storage": "granted",
      "wait_for_update": 500
    });

    gtag("set", "ads_data_redaction", true);
    gtag("set", "url_passthrough", true);

    log("Google Consent Mode v2 initialized");
  }

  function updateGoogleConsent(consent) {
    if (!PhoenixKitConsent.config.googleConsentMode) return;

    window.dataLayer = window.dataLayer || [];
    function gtag() { window.dataLayer.push(arguments); }

    gtag("consent", "update", {
      "analytics_storage": consent.analytics ? "granted" : "denied",
      "ad_storage": consent.marketing ? "granted" : "denied",
      "ad_user_data": consent.marketing ? "granted" : "denied",
      "ad_personalization": consent.marketing ? "granted" : "denied",
      "personalization_storage": consent.preferences ? "granted" : "denied"
    });

    log("Google Consent Mode updated", consent);
  }

  // =====================================================
  // SCRIPT BLOCKING
  // =====================================================

  function blockScripts() {
    var scripts = document.querySelectorAll("script[data-consent-category]");
    scripts.forEach(function(script) {
      var category = script.getAttribute("data-consent-category");
      if (category !== "necessary") {
        script.setAttribute("type", "text/plain");
        script.setAttribute("data-blocked", "true");
      }
    });
    log("Non-essential scripts blocked");
  }

  function unblockScripts(category) {
    var scripts = document.querySelectorAll(
      'script[data-consent-category="' + category + '"][data-blocked="true"]'
    );

    scripts.forEach(function(script) {
      var newScript = document.createElement("script");
      Array.from(script.attributes).forEach(function(attr) {
        if (attr.name !== "type" && attr.name !== "data-blocked") {
          newScript.setAttribute(attr.name, attr.value);
        }
      });
      if (script.src) {
        newScript.src = script.src;
      } else {
        newScript.textContent = script.textContent;
      }
      script.parentNode.replaceChild(newScript, script);
    });

    if (scripts.length > 0) {
      log("Scripts unblocked for category: " + category);
    }
  }

  function applyConsent(consent) {
    CATEGORIES.forEach(function(category) {
      if (consent[category]) {
        unblockScripts(category);
      }
    });

    updateGoogleConsent(consent);

    window.dispatchEvent(new CustomEvent("phx:consent-updated", {
      detail: { consent: consent }
    }));
  }

  // =====================================================
  // DOM CREATION
  // =====================================================

  function getIconPositionClass(position) {
    switch(position) {
      case "bottom-left": return "bottom: 1rem; left: 1rem;";
      case "top-left": return "top: 1rem; left: 1rem;";
      case "top-right": return "top: 1rem; right: 1rem;";
      default: return "bottom: 1rem; right: 1rem;";
    }
  }

  function createWidgetHTML(config) {
    var showIcon = isOptInMode();
    var iconStyle = getIconPositionClass(config.icon_position || config.iconPosition);

    // Use daisyUI CSS variables for theme support
    return '<div id="pk-consent-root" class="pk-consent-widget">' +
      '<style>' +
        // CSS variables using daisyUI theme colors
        '.pk-consent-widget{' +
          '--pk-bg:oklch(var(--b1));' +
          '--pk-bg-alt:oklch(var(--b2));' +
          '--pk-border:oklch(var(--b3));' +
          '--pk-text:oklch(var(--bc));' +
          '--pk-text-muted:oklch(var(--bc)/0.6);' +
          '--pk-primary:oklch(var(--p));' +
          '--pk-primary-content:oklch(var(--pc));' +
          '--pk-primary-soft:oklch(var(--p)/0.1);' +
          '--pk-primary-glow:oklch(var(--p)/0.4);' +
          '--pk-shadow:0 8px 32px oklch(var(--bc)/0.12);' +
        '}' +
        '@keyframes pk-breathe{0%,100%{box-shadow:0 0 0 0 var(--pk-primary-glow),0 4px 12px oklch(var(--bc)/0.15)}50%{box-shadow:0 0 0 8px transparent,0 4px 16px oklch(var(--bc)/0.2)}}' +
        '@keyframes pk-slide-up{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}' +
        '@keyframes pk-fade-in{from{opacity:0}to{opacity:1}}' +
        '.pk-floating-icon{animation:pk-breathe 3s ease-in-out infinite;transition:transform 0.2s cubic-bezier(0.34,1.56,0.64,1),box-shadow 0.2s ease}' +
        '.pk-floating-icon:hover{transform:scale(1.1);animation:none;box-shadow:0 0 0 4px var(--pk-primary-glow),0 8px 24px oklch(var(--bc)/0.25)}' +
        '.pk-floating-icon:active{transform:scale(0.95)}' +
        '.pk-banner{animation:pk-slide-up 0.4s cubic-bezier(0.16,1,0.3,1) forwards}' +
        '.pk-modal-backdrop{animation:pk-fade-in 0.2s ease forwards}' +
        '.pk-modal-content{animation:pk-slide-up 0.3s cubic-bezier(0.16,1,0.3,1) forwards}' +
        '.pk-glass{background:oklch(var(--b1)/0.95);backdrop-filter:blur(20px) saturate(180%);-webkit-backdrop-filter:blur(20px) saturate(180%);border:1px solid var(--pk-border);box-shadow:var(--pk-shadow)}' +
        '.pk-category-card{transition:all 0.2s ease;background:var(--pk-bg-alt);border:1px solid var(--pk-border)}' +
        '.pk-category-card:hover{transform:translateY(-2px);box-shadow:0 4px 12px oklch(var(--bc)/0.1)}' +
        '.pk-toggle-track{background:var(--pk-border);transition:background 0.2s}' +
        '.pk-toggle-track.active{background:var(--pk-primary)}' +
        '.pk-toggle-thumb{background:var(--pk-bg);box-shadow:0 1px 3px oklch(var(--bc)/0.2)}' +
      '</style>' +

      // Floating Icon - using theme colors
      (showIcon ?
        '<button id="pk-consent-icon" type="button" onclick="window.PhoenixKitConsent.openPreferences()" ' +
        'class="pk-floating-icon pk-glass" ' +
        'style="position:fixed;z-index:50;width:3rem;height:3rem;border-radius:9999px;display:flex;align-items:center;justify-content:center;cursor:pointer;background:var(--pk-primary);' + iconStyle + '" ' +
        'aria-label="' + escapeAttr(t("icon_aria_label", "Cookie preferences")) + '" title="' + escapeAttr(t("icon_aria_label", "Cookie preferences")) + '">' +
          '<svg style="width:1.5rem;height:1.5rem;color:var(--pk-primary-content)" viewBox="0 0 24 24" fill="currentColor">' +
            '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>' +
          '</svg>' +
        '</button>' : '') +

      // Banner - using theme colors
      '<div id="pk-consent-banner" class="pk-banner pk-glass" style="position:fixed;bottom:0;left:0;right:0;z-index:50;display:none;border-radius:0" role="dialog" aria-label="' + escapeAttr(t("banner_aria_label", "Cookie consent")) + '" aria-hidden="true">' +
        '<div style="max-width:64rem;margin:0 auto;padding:1rem 1.5rem">' +
          '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:1rem">' +
            '<div style="flex:1;display:flex;align-items:flex-start;gap:0.75rem;min-width:200px">' +
              '<div style="flex-shrink:0;width:2.5rem;height:2.5rem;border-radius:9999px;background:var(--pk-primary-soft);display:flex;align-items:center;justify-content:center">' +
                '<svg style="width:1.25rem;height:1.25rem;color:var(--pk-primary)" viewBox="0 0 24 24" fill="currentColor">' +
                  '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93z"/>' +
                '</svg>' +
              '</div>' +
              '<div>' +
                '<h3 style="font-weight:600;font-size:0.875rem;margin:0;color:var(--pk-text)">' + escapeText(t("banner_title", "We value your privacy")) + '</h3>' +
                '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0.25rem 0 0 0">' +
                  escapeText(t("banner_message", "We use cookies to enhance your browsing experience and analyze our traffic.")) + ' ' +
                  '<a href="' + escapeAttr(config.cookie_policy_url || '/legal/cookie-policy') + '" style="color:var(--pk-primary);text-decoration:underline" target="_blank">' + escapeText(t("cookie_policy_label", "Cookie Policy")) + '</a>' +
                '</p>' +
              '</div>' +
            '</div>' +
            '<div style="display:flex;gap:0.5rem;flex-wrap:wrap">' +
              '<button type="button" onclick="window.PhoenixKitConsent.openPreferences()" class="btn btn-ghost btn-sm" style="font-size:0.75rem">' + escapeText(t("customize", "Customize")) + '</button>' +
              '<button type="button" onclick="window.PhoenixKitConsent.rejectAll()" class="btn btn-outline btn-sm" style="font-size:0.75rem">' + escapeText(t("reject", "Reject")) + '</button>' +
              '<button type="button" onclick="window.PhoenixKitConsent.acceptAll()" class="btn btn-primary btn-sm" style="font-size:0.75rem">' + escapeText(t("accept_all", "Accept All")) + '</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>' +

      // Modal - using theme colors
      '<div id="pk-consent-modal" style="position:fixed;inset:0;z-index:100;display:none" role="dialog" aria-modal="true" aria-label="' + escapeAttr(t("icon_aria_label", "Cookie preferences")) + '">' +
        '<div class="pk-modal-backdrop" onclick="window.PhoenixKitConsent.closePreferences()" style="position:absolute;inset:0;background:oklch(var(--bc)/0.4);backdrop-filter:blur(4px)"></div>' +
        '<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:1rem;pointer-events:none">' +
          '<div class="pk-modal-content pk-glass" style="width:100%;max-width:28rem;max-height:85vh;overflow:hidden;border-radius:1rem;pointer-events:auto">' +
            // Modal Header
            '<div style="display:flex;align-items:center;justify-content:space-between;padding:1rem 1.5rem;border-bottom:1px solid var(--pk-border)">' +
              '<div style="display:flex;align-items:center;gap:0.75rem;flex:1">' +
                '<div style="width:2.5rem;height:2.5rem;border-radius:9999px;background:var(--pk-primary-soft);display:flex;align-items:center;justify-content:center">' +
                  '<svg style="width:1.25rem;height:1.25rem;color:var(--pk-primary)" viewBox="0 0 24 24" fill="currentColor">' +
                    '<path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>' +
                  '</svg>' +
                '</div>' +
                '<div>' +
                  '<h2 style="font-weight:600;font-size:1.125rem;margin:0;color:var(--pk-text)">' + escapeText(t("modal_title", "Privacy Preferences")) + '</h2>' +
                  '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0">' + escapeText(t("modal_subtitle", "Manage your cookie settings")) + '</p>' +
                '</div>' +
              '</div>' +
              '<button type="button" onclick="window.PhoenixKitConsent.closePreferences()" class="btn btn-ghost btn-sm btn-circle" aria-label="' + escapeAttr(t("modal_close_aria", "Close")) + '">' +
                '<svg style="width:1.25rem;height:1.25rem" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">' +
                  '<path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>' +
                '</svg>' +
              '</button>' +
            '</div>' +
            // Categories
            '<div style="padding:1rem 1.5rem;overflow-y:auto;max-height:50vh">' +
              createCategoryHTML("necessary", "🔒", tc("necessary", "name", "Essential"), tc("necessary", "description", "Required for core functionality. Cannot be disabled."), true) +
              createCategoryHTML("analytics", "📊", tc("analytics", "name", "Analytics"), tc("analytics", "description", "Help us understand how you use our site."), false, (config.purposes || {}).analytics) +
              createCategoryHTML("marketing", "📢", tc("marketing", "name", "Marketing"), tc("marketing", "description", "Used for personalized advertising."), false, (config.purposes || {}).marketing) +
              createCategoryHTML("preferences", "⚙️", tc("preferences", "name", "Preferences"), tc("preferences", "description", "Remember your settings and preferences."), false, (config.purposes || {}).preferences) +
            '</div>' +
            // Modal Footer
            '<div style="padding:1rem 1.5rem;border-top:1px solid var(--pk-border);background:var(--pk-bg-alt)">' +
              '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:0.75rem">' +
                '<div style="font-size:0.75rem;color:var(--pk-text-muted)">' +
                  '<a href="' + escapeAttr(config.privacy_policy_url || '/legal/privacy-policy') + '" style="color:inherit;text-decoration:underline" target="_blank">' + escapeText(t("privacy_policy_label", "Privacy Policy")) + '</a>' +
                  ' • ' +
                  '<a href="' + escapeAttr(config.cookie_policy_url || '/legal/cookie-policy') + '" style="color:inherit;text-decoration:underline" target="_blank">' + escapeText(t("cookie_policy_label", "Cookie Policy")) + '</a>' +
                '</div>' +
                '<div style="margin-left:auto;display:flex;gap:0.5rem">' +
                  '<button type="button" onclick="window.PhoenixKitConsent.rejectAll()" class="btn btn-ghost btn-sm" style="font-size:0.75rem">' + escapeText(t("reject_all", "Reject All")) + '</button>' +
                  '<button type="button" onclick="window.PhoenixKitConsent.savePreferences()" class="btn btn-primary btn-sm" style="font-size:0.75rem">' + escapeText(t("save_preferences", "Save Preferences")) + '</button>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>';
  }

  function createCategoryHTML(id, icon, name, description, required, covers) {
    var coversLine = (covers && covers.length) ?
      '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0.25rem 0 0 0" data-covers="' + escapeAttr(id) + '">' +
        '<span style="font-weight:500">' + escapeText(t("covers", "Covers:")) + '</span> ' + escapeText(covers.join(", ")) +
      '</p>' : '';

    var checkedAttr = required ? ' checked disabled' : '';
    var requiredBadge = required ? '<span class="badge badge-ghost badge-xs" style="margin-left:0.5rem">' + escapeText(t("required", "Required")) + '</span>' : '';

    return '<div class="pk-category-card" style="border-radius:0.75rem;padding:1rem;margin-bottom:0.75rem">' +
      '<div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.75rem">' +
        '<div style="display:flex;align-items:flex-start;gap:0.75rem;flex:1">' +
          '<span style="font-size:1.25rem">' + escapeText(icon) + '</span>' +
          '<div>' +
            '<div style="display:flex;align-items:center">' +
              '<span style="font-weight:500;font-size:0.875rem;color:var(--pk-text)">' + escapeText(name) + '</span>' +
              requiredBadge +
            '</div>' +
            '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0.25rem 0 0 0">' + escapeText(description) + '</p>' +
            coversLine +
          '</div>' +
        '</div>' +
        '<label style="position:relative;display:inline-flex;cursor:pointer;flex-shrink:0">' +
          '<input type="checkbox" id="pk-consent-' + escapeAttr(id) + '" class="toggle toggle-primary toggle-sm" data-category="' + escapeAttr(id) + '"' + checkedAttr + '>' +
        '</label>' +
      '</div>' +
    '</div>';
  }

  function injectWidget(config) {
    // Remove existing widget if any
    var existing = document.getElementById("pk-consent-root");
    if (existing) {
      existing.remove();
    }

    // Create widget container
    var container = document.createElement("div");
    container.innerHTML = createWidgetHTML(config);
    document.body.appendChild(container.firstChild);

    log("Widget injected into DOM");
  }

  // =====================================================
  // UI MANAGEMENT
  // =====================================================

  function showBanner() {
    var banner = document.getElementById("pk-consent-banner");
    if (banner) {
      banner.classList.remove("hidden");
      banner.style.display = "block";
      banner.setAttribute("aria-hidden", "false");
    }
  }

  function hideBanner() {
    var banner = document.getElementById("pk-consent-banner");
    if (banner) {
      banner.style.display = "none";
      banner.setAttribute("aria-hidden", "true");
    }
  }

  function showIcon() {
    var icon = document.getElementById("pk-consent-icon");
    if (icon && isOptInMode()) {
      icon.style.display = "flex";
      icon.style.opacity = "1";
    }
  }

  function hideIcon() {
    var icon = document.getElementById("pk-consent-icon");
    if (icon) {
      icon.style.opacity = "0";
    }
  }

  function showModal() {
    var modal = document.getElementById("pk-consent-modal");
    if (modal) {
      modal.classList.remove("hidden");
      modal.style.display = "block";
      hideBanner();
      setTimeout(function() {
        var firstButton = modal.querySelector("button");
        if (firstButton) firstButton.focus();
      }, 100);
    }
  }

  function hideModal() {
    var modal = document.getElementById("pk-consent-modal");
    if (modal) {
      modal.style.display = "none";
    }
  }

  function updateCheckboxes() {
    var consent = PhoenixKitConsent.consent || {};
    CATEGORIES.forEach(function(category) {
      var checkbox = document.getElementById("pk-consent-" + category);
      if (checkbox && !checkbox.disabled) {
        checkbox.checked = !!consent[category];
      }
    });
  }

  function readCheckboxes() {
    var preferences = { necessary: true };
    CATEGORIES.forEach(function(category) {
      if (category === "necessary") return;
      var checkbox = document.getElementById("pk-consent-" + category);
      preferences[category] = checkbox ? checkbox.checked : false;
    });
    return preferences;
  }

  function updateUI() {
    if (shouldShowBanner()) {
      showBanner();
      hideIcon();
    } else {
      hideBanner();
      showIcon();
    }
    updateCheckboxes();
  }

  // =====================================================
  // PUBLIC API
  // =====================================================

  PhoenixKitConsent.acceptAll = function() {
    var consent = {
      necessary: true,
      analytics: true,
      marketing: true,
      preferences: true,
      timestamp: new Date().toISOString()
    };

    decide(consent, "banner");
    hideBanner();
    hideModal();
    showIcon();

    log("All cookies accepted");
  };

  PhoenixKitConsent.rejectAll = function() {
    var consent = {
      necessary: true,
      analytics: false,
      marketing: false,
      preferences: false,
      timestamp: new Date().toISOString()
    };

    decide(consent, "banner");
    hideBanner();
    hideModal();
    showIcon();

    log("Non-essential cookies rejected");
  };

  PhoenixKitConsent.savePreferences = function() {
    var preferences = readCheckboxes();
    preferences.timestamp = new Date().toISOString();

    decide(preferences, "preferences");
    hideModal();
    showIcon();

    log("Preferences saved", preferences);
  };

  PhoenixKitConsent.openPreferences = function() {
    updateCheckboxes();
    showModal();
    log("Preferences modal opened");
  };

  PhoenixKitConsent.closePreferences = function() {
    hideModal();
    log("Preferences modal closed");
  };

  PhoenixKitConsent.getConsent = function() {
    return PhoenixKitConsent.consent;
  };

  PhoenixKitConsent.hasConsent = function(category) {
    return PhoenixKitConsent.consent && !!PhoenixKitConsent.consent[category];
  };

  PhoenixKitConsent.revokeConsent = function() {
    try {
      var before = PhoenixKitConsent.consent;
      localStorage.removeItem(STORAGE_KEY);
      localStorage.removeItem(VERSION_KEY);
      PhoenixKitConsent.consent = null;
      updateUI();
      revokeOnServer().then(function() {
        var none = { necessary: true, analytics: false, marketing: false, preferences: false };
        if (PhoenixKitConsent.config.reloadOnWithdrawal && withdrew(before, none)) {
          window.location.reload();
        }
      });
      log("Consent revoked");
    } catch (e) {
      log("Could not revoke consent", e);
    }
  };

  // =====================================================
  // INITIALIZATION
  // =====================================================

  function initFromConfig(config) {
    PhoenixKitConsent.config = {
      frameworks: config.frameworks || [],
      consentMode: config.consent_mode || "strict",
      policyVersion: config.policy_version || "1.0",
      googleConsentMode: config.google_consent_mode || false,
      iconPosition: config.icon_position || "bottom-right",
      showIcon: config.show_icon || false,
      cookiePolicyUrl: config.cookie_policy_url || "/legal/cookie-policy",
      privacyPolicyUrl: config.privacy_policy_url || "/legal/privacy-policy",
      consentEndpoint: config.consent_endpoint || null,
      cookieName: config.cookie_name || DEFAULT_COOKIE_NAME,
      cookieDays: config.cookie_days || DEFAULT_COOKIE_DAYS,
      reloadOnWithdrawal: config.reload_on_withdrawal !== false,
      translations: config.translations || {}
    };

    // Inject widget into DOM
    injectWidget(config);

    // Cache DOM elements
    PhoenixKitConsent.elements = {
      root: document.getElementById("pk-consent-root"),
      icon: document.getElementById("pk-consent-icon"),
      banner: document.getElementById("pk-consent-banner"),
      modal: document.getElementById("pk-consent-modal")
    };

    // Initialize Google Consent Mode (only in strict mode)
    if (PhoenixKitConsent.config.consentMode === "strict") {
      initGoogleConsentMode();
    }

    // Setup cross-tab sync
    setupCrossTabSync();

    // Load existing consent
    restoreConsent();

    // Update UI
    updateUI();

    // Handle Escape key
    document.addEventListener("keydown", function(e) {
      if (e.key === "Escape") {
        hideModal();
      }
    });

    PhoenixKitConsent.initialized = true;
    log("Initialized with config", PhoenixKitConsent.config);
  }

  function initFromElement(rootElement) {
    var config = {
      frameworks: JSON.parse(rootElement.dataset.frameworks || "[]"),
      consent_mode: rootElement.dataset.consentMode || "strict",
      policy_version: rootElement.dataset.policyVersion || "1.0",
      google_consent_mode: rootElement.dataset.googleConsentMode === "true",
      icon_position: rootElement.dataset.iconPosition || "bottom-right",
      show_icon: rootElement.dataset.showIcon === "true",
      cookie_policy_url: rootElement.dataset.cookiePolicyUrl || "/legal/cookie-policy",
      privacy_policy_url: rootElement.dataset.privacyPolicyUrl || "/legal/privacy-policy",
      consent_endpoint: rootElement.dataset.consentEndpoint || null,
      cookie_name: rootElement.dataset.cookieName || DEFAULT_COOKIE_NAME,
      cookie_days: parseInt(rootElement.dataset.cookieDays, 10) || DEFAULT_COOKIE_DAYS,
      reload_on_withdrawal: rootElement.dataset.reloadOnWithdrawal !== "false"
    };

    PhoenixKitConsent.config = {
      frameworks: config.frameworks,
      consentMode: config.consent_mode,
      policyVersion: config.policy_version,
      googleConsentMode: config.google_consent_mode,
      iconPosition: config.icon_position,
      showIcon: config.show_icon,
      cookiePolicyUrl: config.cookie_policy_url,
      privacyPolicyUrl: config.privacy_policy_url,
      consentEndpoint: config.consent_endpoint,
      cookieName: config.cookie_name,
      cookieDays: config.cookie_days,
      reloadOnWithdrawal: config.reload_on_withdrawal,
      translations: {}
    };

    PhoenixKitConsent.elements = {
      root: rootElement,
      icon: document.getElementById("pk-consent-icon"),
      banner: document.getElementById("pk-consent-banner"),
      modal: document.getElementById("pk-consent-modal")
    };

    // Initialize Google Consent Mode (only in strict mode)
    if (PhoenixKitConsent.config.consentMode === "strict") {
      initGoogleConsentMode();
    }

    setupCrossTabSync();

    restoreConsent();

    updateUI();

    document.addEventListener("keydown", function(e) {
      if (e.key === "Escape") {
        hideModal();
      }
    });

    PhoenixKitConsent.initialized = true;
    log("Initialized from element", PhoenixKitConsent.config);
  }

  // Manual API: fetch config from server and inject widget.
  // Not called from auto-init — the server decides visibility at render time
  // via the cookie_consent component's phoenix_kit_current_scope attr.
  //
  // WARNING: calling window.PhoenixKitConsent.init() from a third-party page
  // BYPASSES the server-side auth gate. The config API backing this call is
  // auth-agnostic by design (cacheable, no per-request user check), so the
  // widget will render regardless of whether the current user is authenticated.
  // If you call init() on pages where authenticated users should not see the
  // widget, you MUST perform your own auth check before calling it.
  function fetchConfigAndInit() {
    fetch(getConfigEndpoint(), { credentials: "same-origin" })
      .then(function(response) {
        if (!response.ok) {
          throw new Error("Config endpoint returned " + response.status);
        }
        return response.json();
      })
      .then(function(config) {
        if (PhoenixKitConsent.initialized) return;
        if (!config.enabled) return;

        var existingRoot = document.getElementById("pk-consent-root");
        if (existingRoot) {
          initFromElement(existingRoot);
        } else {
          initFromConfig(config);
        }
      })
      .catch(function(err) {
        log("Could not fetch config", err);
      });
  }

  // =====================================================
  // PHOENIX LIVEVIEW HOOK
  // =====================================================

  var CookieConsentHook = {
    mounted: function() {
      if (!PhoenixKitConsent.initialized) {
        initFromElement(this.el);
      }
    },
    destroyed: function() {
      PhoenixKitConsent.initialized = false;
    }
  };

  // Export hook for Phoenix LiveView
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  // A LiveSocket built before this script ran holds the older copy's hook
  // object; rewriting that object's callbacks in place reaches it, where
  // assigning a new object would not.
  var previousHook = window.PhoenixKitHooks.CookieConsent;
  if (previous && previousHook && typeof previousHook === "object") {
    previousHook.mounted = CookieConsentHook.mounted;
    previousHook.destroyed = CookieConsentHook.destroyed;
  }

  window.PhoenixKitHooks.CookieConsent = CookieConsentHook;

  // What `js_sources/0` names: core's bundle compiler folds this into
  // `window.PhoenixKitHooks` on hosts that load `phoenix_kit_modules.js`.
  window.PhoenixKitLegalHooks = { CookieConsent: CookieConsentHook };

  // Expose manual-injection entry point for third-party / non-LiveView contexts.
  PhoenixKitConsent.init = fetchConfigAndInit;

  // Export module
  window.PhoenixKitConsent = PhoenixKitConsent;

  // Auto-init. The LiveView hook may already have initialized via `mounted`;
  // the `initialized` guard prevents a second run.
  // The server decides visibility at render time: with a server-rendered
  // `#pk-consent-root`, initialize from it; without one, do nothing — the
  // user is signed in (hidden) or the widget is off.
  //
  // The exception is a page that was relying on the older bundled copy to
  // inject the widget (a host layout with no component in it). Having
  // retired that copy, this script injects in its place.
  function autoInit() {
    if (PhoenixKitConsent.initialized) return;
    var root = document.getElementById("pk-consent-root");
    if (root) {
      initFromElement(root);
    } else if (previous) {
      fetchConfigAndInit();
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", autoInit);
  } else {
    autoInit();
  }

})();
