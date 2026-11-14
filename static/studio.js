"use strict";

const $ = (id) => document.getElementById(id);
const audio = $("audio");
const speech = window.speechSynthesis;
const state = {
  book: null, lines: new Map(), index: 0, playing: false, ended: false,
  generation: 0, opening: 0, speech: null, audioIndex: -1, audioURL: null,
  prefetch: new Map(), mode: "link", file: null, account: null, voiceOptions: null,
};

async function api(path, options) {
  const response = await fetch(path, options);
  const data = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(typeof data.detail === "string" ? data.detail : "The request could not be completed.");
    error.status = response.status;
    throw error;
  }
  return data;
}

function json(method, value = {}) {
  return { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(value) };
}

function status(id, message = "", error = false) {
  const node = $(id);
  node.textContent = message;
  node.classList.toggle("error", error);
}

let noticeTimer;
function notice(message, error = false) {
  clearTimeout(noticeTimer);
  $("notice").hidden = false;
  status("notice", message, error);
  noticeTimer = setTimeout(() => { $("notice").hidden = true; }, 4500);
}

function make(tag, text, className) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function savedLine(id) {
  try { return Number(localStorage.getItem("voiceemo:position:" + id) ?? localStorage.getItem("pos:" + id)) || 0; }
  catch { return 0; }
}

function saveLine(id, index) {
  try { localStorage.setItem("voiceemo:position:" + id, index); } catch { /* storage may be disabled */ }
}

function planOption(plan) {
  return new Option(plan.name + " · " + plan.books_per_period
    + (plan.books_per_period === 1 ? " book" : " books") + " per billing period", plan.id);
}

function previewPrompt() {
  if (!state.book || state.book.unlocked) return;
  renderPurchaseOptions();
  status("unlock-message", state.ended
    ? "You’ve reached the end of your free preview."
    : "Listen to the opening before continuing.");
}

function renderPurchaseOptions() {
  const account = state.account;
  const plan = $("purchase-plan");
  const previous = plan.value;
  const options = [];
  if (account?.one_off_available ?? account?.billing_enabled) options.push(new Option("This audiobook", "book"));
  if (!account?.has_subscription) options.push(...(account?.plans || []).map(planOption));
  if (account?.credits > 0) options.unshift(new Option("Use a credit (" + account.credits + " available)", "credit"));
  plan.replaceChildren(...options);
  if (options.some((option) => option.value === previous)) plan.value = previous;
  $("purchase-option").hidden = !account?.billing_enabled || !options.length;
  updateUnlockLabel();
}

function updateUnlockLabel() {
  $("unlock").textContent = !state.account?.billing_enabled ? "Continue to full audiobook"
    : $("purchase-plan").value === "credit" ? "Use a book credit" : "Unlock full audiobook";
}
$("purchase-plan").onchange = updateUnlockLabel;

function selectMode(mode) {
  state.mode = mode;
  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
  });
  document.querySelectorAll("[data-panel]").forEach((panel) => { panel.hidden = panel.dataset.panel !== mode; });
}

function useFile(file) {
  selectMode("file");
  state.file = null;
  $("file-label").textContent = "Choose a file or drag it here";
  if (!file) return;
  if (!/\.(epub|pdf|docx|txt)$/i.test(file.name) || file.size > 100_000_000) {
    $("story-file").value = "";
    status("import-status", "Choose an EPUB, PDF, DOCX or TXT file up to 100 MB.", true);
    return;
  }
  state.file = file;
  $("file-label").textContent = file.name;
  status("import-status", "Free preview. No account or card required.");
}

document.querySelectorAll("[data-mode]").forEach((button) => {
  button.onclick = () => {
    selectMode(button.dataset.mode);
    status("import-status", "Free preview. No account or card required.");
  };
});
$("story-file").onchange = (event) => useFile(event.target.files[0]);
$("import-form").ondragover = (event) => {
  if (!event.dataTransfer.types.includes("Files")) return;
  event.preventDefault();
  selectMode("file");
  $("import-form").classList.add("dragging");
};
$("import-form").ondragleave = (event) => {
  if (!$("import-form").contains(event.relatedTarget)) $("import-form").classList.remove("dragging");
};
$("import-form").ondrop = (event) => {
  if (!event.dataTransfer.files.length) return;
  event.preventDefault();
  $("import-form").classList.remove("dragging");
  useFile(event.dataTransfer.files[0]);
};

$("import-form").onsubmit = async (event) => {
  event.preventDefault();
  const form = new FormData();
  if (state.mode === "file" && state.file) form.set("file", state.file);
  if (state.mode === "link" && $("story-link").value.trim()) form.set("url", $("story-link").value.trim());
  if (state.mode === "text" && $("story-text").value.trim()) form.set("text", $("story-text").value.trim());
  if (!Array.from(form.keys()).length) {
    status("import-status", { file: "Choose a story file.", link: "Enter a story link.", text: "Paste your story." }[state.mode], true);
    return;
  }
  const opener = ++state.opening;
  $("import-submit").disabled = true;
  status("import-status", "Reading the story and casting its voices…");
  try {
    const book = await api("/api/import", { method: "POST", body: form });
    if (opener === state.opening) openBook(book);
    status("import-status", "Preview ready and saved in your library.");
    refreshLibrary();
  } catch (error) {
    status("import-status", error.message, true);
  } finally {
    $("import-submit").disabled = false;
  }
};

async function refreshLibrary() {
  try {
    const { books } = await api("/api/my/books");
    $("my-books").replaceChildren(...books.map((book) => {
      const card = make("article", "", "my-book");
      const open = make("button");
      open.type = "button";
      open.append(make("strong", book.title), make("span", book.unlocked ? "Full audiobook" : "Free preview"));
      open.onclick = () => loadBook(book.id, open);
      const remove = make("button", "×", "round remove-book");
      remove.type = "button";
      remove.setAttribute("aria-label", "Remove " + book.title);
      remove.onclick = async () => {
        if (!window.confirm("Remove “" + book.title + "” from your library?")) return;
        remove.disabled = true;
        try {
          await api("/api/my/books/" + book.id, { method: "DELETE" });
          if (state.book?.id === book.id) clearPlayer();
          refreshLibrary();
        } catch (error) {
          notice(error.message, true);
          remove.disabled = false;
        }
      };
      card.append(open, remove);
      return card;
    }));
    $("library-info").textContent = books.length
      ? (state.account?.signed_in ? "Your saved audiobooks." : "Your stories are saved in this browser.")
      : "Stories you preview will appear here.";
  } catch (error) {
    $("library-info").textContent = error.message;
  }
}

let catalogRequest = 0;
async function loadCatalog(query = "") {
  const request = ++catalogRequest;
  status("catalog-status", query ? "Searching…" : "Loading featured books…");
  $("catalog-books").replaceChildren();
  try {
    const path = query ? "/api/library/search?q=" + encodeURIComponent(query) : "/api/library/featured";
    const { items } = await api(path);
    if (request !== catalogRequest) return;
    status("catalog-status", items.length ? "" : "No public-domain titles matched that search.");
    $("catalog-books").replaceChildren(...items.map((book) => {
      const button = make("button", "", "catalog-book");
      const cover = make("div", book.title, "cover-fallback");
      if (book.cover) {
        try {
          const url = new URL(book.cover);
          if (url.protocol === "https:") {
            const img = make("img");
            img.alt = "";
            img.loading = "lazy";
            img.referrerPolicy = "no-referrer";
            img.onerror = () => img.replaceWith(cover);
            img.src = url.href;
            button.append(img);
          }
        } catch { /* fall back to the title */ }
      }
      if (!button.firstChild) button.append(cover);
      button.append(make("strong", book.title), make("small", book.authors.join(", ")));
      button.onclick = async () => {
        const opener = ++state.opening;
        button.disabled = true;
        status("catalog-status", "Preparing “" + book.title + "”…");
        try {
          const result = await api("/api/library/open", json("POST", { google_id: book.id }));
          if (opener === state.opening) openBook(result);
          status("catalog-status");
        } catch (error) {
          status("catalog-status", error.message, true);
        } finally {
          button.disabled = false;
        }
      };
      return button;
    }));
  } catch (error) {
    if (request === catalogRequest) status("catalog-status", error.message, true);
  }
}

$("catalog-search").onsubmit = (event) => {
  event.preventDefault();
  loadCatalog($("catalog-query").value.trim());
};
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    if (!entries.some((entry) => entry.isIntersecting)) return;
    observer.disconnect();
    if (!catalogRequest) loadCatalog();
  }, { rootMargin: "100px" });
  observer.observe($("catalog"));
} else {
  loadCatalog();
}

async function loadBook(id, button) {
  const opener = ++state.opening;
  if (button) button.disabled = true;
  try {
    const book = await api("/api/books/" + encodeURIComponent(id));
    if (opener === state.opening) openBook(book);
  } catch (error) {
    notice(error.message, true);
  } finally {
    if (button) button.disabled = false;
  }
}

function available() { return state.book?.preview_lines || 0; }
function bookPath() { return "/api/books/" + state.book.id; }

function resetAudio() {
  audio.pause();
  audio.removeAttribute("src");
  audio.load();
  if (state.audioURL) URL.revokeObjectURL(state.audioURL);
  state.audioURL = null;
  state.audioIndex = -1;
  state.prefetch.clear();
}

function clearPlayer() {
  stop();
  resetAudio();
  state.book = null;
  state.lines.clear();
  $("player").close();
  $("mini-player").hidden = true;
}

function openBook(book, requestedIndex = savedLine(book.id)) {
  stop();
  resetAudio();
  state.book = book;
  state.lines = new Map(book.lines.map((line) => [line.i, line]));
  $("transcript").replaceChildren();
  state.index = Math.max(0, Math.min(requestedIndex, available() - 1));
  state.ended = false;
  $("player-mode").textContent = book.unlocked ? "Audiobook" : "Free preview";
  $("player-title").textContent = book.title;
  $("player-author").textContent = book.author || "";
  $("mini-title").textContent = book.title;
  $("mini-player").hidden = false;
  $("unlock-row").hidden = book.unlocked;
  $("unlock").disabled = false;
  $("check-cast").hidden = !(book.unlocked && book.ai_available);
  $("export").hidden = !(book.unlocked && book.provider !== "browser");
  $("export").disabled = false;
  $("check-cast").disabled = false;
  $("download").hidden = true;
  status("job-status");
  status("player-status");
  $("chapter").replaceChildren(...book.chapters.map((chapter) => new Option(chapter.title, chapter.start)));
  $("chapter").hidden = $("chapter-label").hidden = book.chapters.length < 2;
  previewPrompt();
  renderCast(book);
  if (!$("player").open) $("player").showModal();
  updatePosition();
  loadLines(book, state.index).then(() => {
    if (book === state.book) updatePosition();
  }).catch((error) => {
    if (book === state.book) status("player-status", error.message, true);
  });
  if (!$("export").hidden) {
    api(bookPath() + "/export").then((job) => {
      if (book === state.book && job.state !== "none") showExport(job, book);
    }).catch(() => {});
  }
}

async function loadLines(book, index) {
  const start = Math.max(0, index - 10);
  const end = Math.min(available(), index + 23);
  const needed = Array.from({ length: end - start }, (_, offset) => start + offset);
  if (needed.every((i) => state.lines.has(i))) return;
  const path = "/api/books/" + book.id + "/lines?start=" + start + "&count=" + (end - start);
  const { lines } = await api(path);
  if (book === state.book) for (const line of lines) state.lines.set(line.i, line);
}

function updatePosition() {
  if (!state.book) return;
  const start = Math.max(0, state.index - 8);
  const end = Math.min(available(), state.index + 18);
  const transcript = $("transcript");
  const first = transcript.firstElementChild?.dataset.line;
  const last = transcript.lastElementChild?.dataset.line;
  if (first === undefined || Number(first) > state.index || Number(last) < Math.min(end - 1, state.index + 4)
      || transcript.dataset.book !== state.book.id) {
    transcript.dataset.book = state.book.id;
    const entries = [];
    for (let i = start; i < end; i++) {
      const line = state.lines.get(i);
      if (!line) continue;
      const button = make("button", "", "transcript-line");
      button.type = "button";
      button.dataset.line = i;
      button.append(make("strong", line.speaker), document.createTextNode(line.text));
      button.onclick = () => playLine(i);
      entries.push(button);
    }
    transcript.replaceChildren(...entries);
  }
  const active = transcript.querySelector('[data-line="' + state.index + '"]');
  transcript.querySelector("[aria-current]")?.removeAttribute("aria-current");
  if (active) {
    active.setAttribute("aria-current", "true");
    transcript.scrollTop += active.getBoundingClientRect().top - transcript.getBoundingClientRect().top - 14;
  }
  $("seek").max = Math.max(0, available() - 1);
  $("seek").value = state.index;
  $("seek").disabled = available() < 2;
  $("position").textContent = (state.index + 1) + " / " + available();
  $("mini-speaker").textContent = state.lines.get(state.index)?.speaker || "";
  $("previous").disabled = state.index === 0;
  $("next").disabled = state.index >= available() - 1;
  const chapter = state.book.chapters.findLast((item) => item.start <= state.index);
  if (chapter) $("chapter").value = chapter.start;
}

async function renderCast(book) {
  const list = $("cast-voices");
  list.replaceChildren(...Object.keys(book.cast).map((name) => make("p", name)));
  try {
    const voices = state.voiceOptions ?? await api("/api/voices");
    if (book !== state.book) return;
    state.voiceOptions = voices;
    list.replaceChildren(...Object.entries(book.cast).map(([name, character]) => {
      const label = make("label", name);
      const select = make("select");
      select.setAttribute("aria-label", "Voice for " + name);
      for (const [slot, voice] of Object.entries(voices)) select.add(new Option(voice.name, slot));
      select.value = character.voice;
      select.onchange = async () => {
        const wasPlaying = state.playing;
        stop();
        resetAudio();
        select.disabled = true;
        try {
          book.cast = await api(bookPath() + "/cast", json("POST", { speaker: name, voice: select.value }));
          if (book === state.book) {
            $("download").hidden = true;
            $("export").disabled = false;
            status("job-status", "Voice updated.");
            if (wasPlaying) playLine(state.index);
          }
        } catch (error) {
          select.value = character.voice;
          if (book === state.book) status("job-status", error.message, true);
        } finally {
          select.disabled = false;
        }
      };
      label.append(select);
      return label;
    }));
  } catch {
    /* The speaker list remains readable when voice choices are unavailable. */
  }
}

function setPlaying(playing) {
  state.playing = playing;
  for (const control of [$("play"), $("mini-play")]) {
    control.textContent = playing ? "Ⅱ" : "▶";
    control.setAttribute("aria-label", playing ? "Pause" : "Play");
  }
}

function stop(preserve = false) {
  state.generation++;
  audio.pause();
  if (state.speech) {
    if (preserve) {
      speech.pause();
    } else {
      state.speech = null;
      speech.cancel();
      if (speech.paused) speech.resume();
    }
  }
  setPlaying(false);
}

function fetchAudio(book, index) {
  if (state.prefetch.has(index)) return state.prefetch.get(index);
  const requests = state.prefetch;
  const promise = fetch("/api/books/" + book.id + "/lines/" + index + "/audio").then(async (response) => {
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      throw new Error(error.detail || "Audio could not be generated.");
    }
    return response.blob();
  });
  requests.set(index, promise);
  promise.catch(() => { if (requests.get(index) === promise) requests.delete(index); });
  for (const key of requests.keys()) if (Math.abs(key - index) > 4) requests.delete(key);
  return promise;
}

function advance() {
  if (!state.playing) return;
  if (state.index + 1 < available()) {
    playLine(state.index + 1);
    return;
  }
  setPlaying(false);
  state.ended = true;
  if (state.book.unlocked) {
    saveLine(state.book.id, 0);
    status("player-status", "You’ve reached the end of the audiobook.");
  }
  previewPrompt();
}

function playSpeech(book, line) {
  if (!speech || typeof SpeechSynthesisUtterance !== "function") {
    setPlaying(false);
    status("player-status", "This browser has no speech playback available.", true);
    return;
  }
  const utterance = new SpeechSynthesisUtterance(line.text);
  const character = book.cast[line.speaker] ?? book.cast.Narrator;
  const slots = ["narrator_f", "narrator_m", "m1", "m2", "m3", "m4", "m5", "f1", "f2", "f3", "f4"];
  const slot = Math.max(0, slots.indexOf(character.voice));
  const preferred = speech.getVoices().filter((voice) => voice.lang.startsWith("en"));
  const voices = preferred.length ? preferred : speech.getVoices();
  if (voices.length) utterance.voice = voices[slot % voices.length];
  const emotion = { happy: 1.13, excited: 1.18, sad: .9, scared: 1.16, whisper: .9, angry: .91 };
  utterance.pitch = Math.min(1.8, (.8 + slot * .048) * (emotion[line.emotion] || 1));
  utterance.rate = Number($("speed").value);
  if (line.emotion === "whisper") utterance.volume = .68;
  state.speech = utterance;
  utterance.onend = () => {
    if (state.speech !== utterance) return;
    state.speech = null;
    advance();
  };
  utterance.onerror = () => {
    if (state.speech !== utterance) return;
    state.speech = null;
    setPlaying(false);
    status("player-status", "The browser could not play this line. Press play to retry.", true);
  };
  speech.speak(utterance);
}

async function playLine(index) {
  const book = state.book;
  if (!book || !available()) return;
  stop();
  window.dispatchEvent(new Event("voiceemo:studio-play"));
  state.index = Math.max(0, Math.min(index, available() - 1));
  if (state.ended) {
    state.ended = false;
    previewPrompt();
  }
  const generation = state.generation;
  setPlaying(true);
  saveLine(book.id, state.index);
  status("player-status");
  updatePosition();
  try {
    const current = state.index;
    if (!state.lines.has(current)) {
      await loadLines(book, current);
      if (generation !== state.generation) return;
      updatePosition();
    } else {
      loadLines(book, current).then(() => {
        if (generation === state.generation) updatePosition();
      }).catch(() => {});
    }
    const line = state.lines.get(current);
    if (!line) throw new Error("This line is unavailable.");
    if (book.provider === "browser") {
      playSpeech(book, line);
      return;
    }
    audio.pause();
    state.audioIndex = -1;
    status("player-status", "Preparing audio…");
    const clip = await fetchAudio(book, current);
    if (generation !== state.generation) return;
    if (state.audioURL) URL.revokeObjectURL(state.audioURL);
    state.audioURL = URL.createObjectURL(clip);
    state.audioIndex = current;
    audio.src = state.audioURL;
    audio.playbackRate = Number($("speed").value);
    await audio.play();
    if (generation !== state.generation) return;
    status("player-status");
    if (current + 1 < available()) fetchAudio(book, current + 1).catch(() => {});
  } catch (error) {
    if (generation !== state.generation) return;
    setPlaying(false);
    status("player-status", error.message, true);
  }
}

function togglePlayback() {
  if (!state.book) return;
  if (state.playing) {
    stop(true);
  } else if (state.ended) {
    playLine(0);
  } else if (state.speech) {
    window.dispatchEvent(new Event("voiceemo:studio-play"));
    setPlaying(true);
    speech.resume();
  } else if (state.audioIndex === state.index && audio.currentTime > 0 && !audio.ended && !audio.error) {
    window.dispatchEvent(new Event("voiceemo:studio-play"));
    setPlaying(true);
    audio.play().catch((error) => {
      if (!audio.paused) return;
      setPlaying(false);
      status("player-status", error.message, true);
    });
  } else {
    playLine(state.index);
  }
}

window.addEventListener("voiceemo:showcase-play", () => stop());
audio.onended = advance;
audio.onerror = () => {
  if (!state.playing || state.audioIndex !== state.index) return;
  setPlaying(false);
  status("player-status", "This audio clip could not play. Press play to retry.", true);
};
$("play").onclick = $("mini-play").onclick = togglePlayback;
$("player-close").onclick = () => $("player").close();
$("mini-open").onclick = () => {
  if (state.book && !$("player").open) {
    $("player").showModal();
    updatePosition();
  }
};
$("previous").onclick = () => playLine(state.index - 1);
$("next").onclick = () => playLine(state.index + 1);
$("seek").onchange = (event) => playLine(Number(event.target.value));
$("chapter").onchange = (event) => playLine(Number(event.target.value));
$("speed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  if (state.playing && state.speech) playLine(state.index);
};

if ("mediaSession" in navigator) {
  for (const [action, handler] of Object.entries({
    play: () => { if (!state.playing) togglePlayback(); },
    pause: () => { if (state.playing) stop(true); },
    previoustrack: () => playLine(state.index - 1),
    nexttrack: () => { if (state.index + 1 < available()) playLine(state.index + 1); },
  })) {
    try { navigator.mediaSession.setActionHandler(action, handler); } catch { /* varies by browser */ }
  }
}

$("unlock").onclick = async () => {
  const book = state.book;
  $("unlock").disabled = true;
  try {
    if (state.account?.billing_enabled) {
      if (!state.account.signed_in) {
        if (!state.account.providers.length) throw new Error("Sign-in is unavailable right now.");
        try { sessionStorage.setItem("voiceemo:auth-book", book.id); } catch { /* optional */ }
        showAccount();
        return;
      }
      const plan = $("purchase-plan").value;
      if (!plan) throw new Error("There are no credits or purchase options available for this book.");
      const path = "/api/my/books/" + book.id;
      const result = plan === "credit"
        ? await api(path + "/spend-credit", json("POST"))
        : await api(path + "/checkout", json("POST", plan && plan !== "book" ? { plan } : {}));
      if (result.url) window.location.assign(result.url);
      else {
        const updated = await api("/api/books/" + book.id);
        if (book === state.book) openBook(updated, state.index);
        await refreshAccount();
        refreshLibrary();
      }
      return;
    }
    await api("/api/my/books/" + book.id + "/unlock", json("POST"));
    const updated = await api("/api/books/" + book.id);
    if (book === state.book) openBook(updated, state.ended ? state.index + 1 : state.index);
    refreshLibrary();
  } catch (error) {
    status("unlock-message", error.message, true);
  } finally {
    $("unlock").disabled = false;
  }
};

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function showExport(job, book) {
  const id = book.id;
  const path = "/api/books/" + id + "/export";
  $("export").disabled = true;
  try {
    while (book === state.book && job.state === "running") {
      status("job-status", "Generating audiobook (" + job.done + " / " + job.total + " lines)…");
      await delay(1250);
      job = await api(path);
    }
    if (book !== state.book) return;
    if (job.state === "ready") {
      $("download").href = path + "/download";
      $("download").hidden = false;
      status("job-status", "Audiobook export ready.");
    } else if (job.state === "error") {
      status("job-status", job.error, true);
    }
  } catch (error) {
    if (book === state.book) status("job-status", error.message, true);
  } finally {
    if (book === state.book) $("export").disabled = false;
  }
}

$("export").onclick = async () => {
  const book = state.book;
  $("export").disabled = true;
  try {
    const job = await api(bookPath() + "/export", json("POST"));
    if (book === state.book) showExport(job, book);
  } catch (error) {
    if (book === state.book) {
      $("export").disabled = false;
      status("job-status", error.message, true);
    }
  }
};

$("check-cast").onclick = async () => {
  const book = state.book;
  const path = bookPath() + "/ai-cast";
  $("check-cast").disabled = true;
  try {
    let job = await api(path, json("POST"));
    while (book === state.book && job.state === "running") {
      status("job-status", job.total ? "Checking casting (" + job.done + " / " + job.total + ")…" : "Checking casting…");
      await delay(1250);
      job = await api(path);
    }
    if (book !== state.book) return;
    if (job.state === "done") {
      const updated = await api("/api/books/" + book.id);
      if (book === state.book) {
        openBook(updated, state.index);
        status("job-status", job.changed ? "Updated " + job.changed + " speaker assignments." : "Casting checked.");
      }
    } else {
      status("job-status", job.error || "Casting review stopped.", true);
    }
  } catch (error) {
    if (book === state.book) status("job-status", error.message, true);
  } finally {
    if (book === state.book) $("check-cast").disabled = false;
  }
};

function showAccount() {
  const account = state.account;
  $("account-title").textContent = account?.signed_in ? "Your account" : "Sign in";
  $("sign-in-options").replaceChildren();
  $("logout").hidden = !account?.signed_in;
  $("manage-billing").hidden = !account?.can_manage_billing;
  $("subscribe-form").hidden = !account?.signed_in || account.has_subscription || !account.plans?.length;
  $("subscribe-plan").replaceChildren(...(account?.plans || []).map(planOption));
  $("email-form").hidden = account?.signed_in || !account?.providers.includes("email");
  status("account-status", account?.signed_in ? account.email || account.name : "");
  for (const provider of account?.signed_in ? [] : account?.providers || []) {
    if (provider === "email") continue;
    const link = make("a", provider === "google" ? "Continue with Google" : "Continue with Discord", "secondary");
    link.href = "/api/auth/" + provider + "/start";
    $("sign-in-options").append(link);
  }
  if (!$("account").open) $("account").showModal();
}

async function refreshAccount() {
  try {
    state.account = await api("/api/account");
    $("account-button").hidden = !state.account.signed_in && !state.account.providers.length;
    $("account-button").textContent = state.account.signed_in ? "Account" : "Sign in";
    previewPrompt();
  } catch {
    $("account-button").hidden = true;
  }
}

$("account-button").onclick = showAccount;
$("account-close").onclick = () => $("account").close();
$("manage-billing").onclick = async () => {
  const button = $("manage-billing");
  button.disabled = true;
  try {
    const { url } = await api("/api/billing/portal", json("POST"));
    window.location.assign(url);
  } catch (error) {
    status("account-status", error.message, true);
    button.disabled = false;
  }
};
$("subscribe-form").onsubmit = async (event) => {
  event.preventDefault();
  const button = $("subscribe-form").querySelector("button");
  button.disabled = true;
  try {
    const { url } = await api("/api/billing/subscribe", json("POST", { plan: $("subscribe-plan").value }));
    window.location.assign(url);
  } catch (error) {
    status("account-status", error.message, true);
    button.disabled = false;
  }
};
$("logout").onclick = async () => {
  try {
    await api("/api/auth/logout", json("POST"));
    clearPlayer();
    $("account").close();
    await refreshAccount();
    refreshLibrary();
  } catch (error) {
    status("account-status", error.message, true);
  }
};
$("email-form").onsubmit = async (event) => {
  event.preventDefault();
  const button = $("email-form").querySelector("button");
  button.disabled = true;
  try {
    await api("/api/auth/email", json("POST", { email: $("email").value }));
    status("account-status", "Check your email for a sign-in link.");
  } catch (error) {
    status("account-status", error.message, true);
  } finally {
    button.disabled = false;
  }
};

async function initialize() {
  const wave = $("wave");
  for (let i = 0; i < 55; i++) {
    const bar = make("i");
    const envelope = .22 + .75 * Math.sin(Math.PI * i / 57);
    const amplitude = envelope * (10 + 82 * Math.abs(Math.sin(i * .47) * Math.cos(i * .13 + .4)));
    bar.style.setProperty("--height", Math.max(amplitude, 3) + "%");
    bar.style.setProperty("--opacity", String(envelope * .7));
    wave.append(bar);
  }
  window.mountShowcase?.($("showcase"));
  const params = new URLSearchParams(location.search);
  let bookId = params.get("book");
  const checkout = params.get("checkout");
  const auth = params.get("auth");
  if (bookId || auth || checkout) history.replaceState(null, "", location.pathname + location.hash);
  await refreshAccount();
  refreshLibrary();
  if (auth === "success") {
    try {
      bookId ||= sessionStorage.getItem("voiceemo:auth-book");
      sessionStorage.removeItem("voiceemo:auth-book");
    } catch { /* optional */ }
    notice("Signed in.");
  } else if (auth === "failed") {
    notice("Sign-in could not be completed. Please try again.", true);
  }
  if (!bookId && checkout === "subscription") {
    notice(state.account?.credits ? "Your plan credits are ready." : "Your subscription is being confirmed.");
    return;
  }
  if (!bookId) return;
  await loadBook(bookId);
  if (checkout === "cancel") status("unlock-message", "Checkout was canceled.");
  if (checkout === "subscription" && state.book?.id === bookId) {
    const book = state.book;
    for (let attempt = 0; !state.account?.credits && attempt < 8; attempt++) {
      status("unlock-message", "Confirming your plan credits…");
      await delay(1250);
      if (book !== state.book) return;
      await refreshAccount();
    }
    status("unlock-message", state.account?.credits
      ? "Your plan is ready. Use a credit to unlock this audiobook."
      : "Plan confirmation is pending. Reopen the book in a moment.");
    return;
  }
  if (checkout === "success" && state.book?.id === bookId && state.book.unlocked) {
    await refreshAccount();
    return;
  }
  if (checkout === "success" && state.book?.id === bookId) {
    const book = state.book;
    for (let attempt = 0; !state.book.unlocked && attempt < 10; attempt++) {
      status("unlock-message", "Confirming your payment…");
      $("unlock").disabled = true;
      await delay(1250);
      if (book !== state.book) return;
      try {
        const updated = await api(bookPath());
        if (updated.unlocked) {
          openBook(updated, state.index);
          await refreshAccount();
          refreshLibrary();
          return;
        }
      } catch { /* try again while the payment is processing */ }
    }
    if (book === state.book) {
      $("unlock").disabled = false;
      status("unlock-message", "Payment confirmation is pending. Reopen the book from your library to check again.");
    }
  }
}

initialize().catch((error) => notice(error.message, true));
