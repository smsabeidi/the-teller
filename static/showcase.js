(function () {
  'use strict';

  const samples = [
    {
      title: 'The Lantern Keeper', genre: 'Mystery', palette: '#b35a39',
      lines: [
        ['Narrator', 'At the end of the pier, the lantern was burning for the first time in twelve years.'],
        ['Nora', 'You saw who lit it?', 'quiet'],
        ['Elias', 'No. But someone has been leaving my name in the keeper’s log.'],
        ['Narrator', 'Nora reached for the door. From the other side, someone turned the handle first.'],
      ],
    },
    {
      title: 'A Letter in Winter', genre: 'Romance', palette: '#995879',
      lines: [
        ['Narrator', 'The post office closed at four, but Clara stayed while the snow covered the village road.'],
        ['Clara', 'I kept the last letter. I was afraid it might be your last.'],
        ['James', 'I thought about writing another every day.', 'quiet'],
        ['Narrator', 'She put the envelope between them, and neither of them reached for it.'],
      ],
    },
    {
      title: 'The Mapmaker’s Door', genre: 'Fantasy', palette: '#7264ad',
      lines: [
        ['Narrator', 'The wall looked solid until Mira traced a river across the map with her thumb.'],
        ['Mira', 'The door wasn’t there before.', 'surprised'],
        ['Ivo', 'Of course it was. You’ve only just drawn where it leads.'],
        ['Narrator', 'Beyond the door, rain was falling upward into a violet sky.'],
      ],
    },
    {
      title: 'Signal From Europa', genre: 'Science fiction', palette: '#39789a',
      lines: [
        ['Narrator', 'The first message from beneath the ice arrived nine minutes before the crew switched on the receiver.'],
        ['Commander Vale', 'Play it again. From the beginning.'],
        ['Imani', 'That’s the part I don’t understand. It begins with us asking to hear it again.', 'quiet'],
        ['Narrator', 'On the waveform, a third voice was about to speak.'],
      ],
    },
    {
      title: 'The Last Train to Bellwick', genre: 'Thriller', palette: '#496a66',
      lines: [
        ['Narrator', 'The train had already left the station when Owen noticed that every clock in his carriage had stopped.'],
        ['Owen', 'Is Bellwick the next stop?'],
        ['The conductor', 'That depends. What time were you expecting to arrive?'],
        ['Narrator', 'Outside, the station they had just left slid past the window again.'],
      ],
    },
    {
      title: 'Table for Three', genre: 'Comedy', palette: '#a27637',
      lines: [
        ['Narrator', 'At seven, a goose walked into the restaurant and stood beside the host’s desk.'],
        ['Ravi', 'I told you there was a reservation under Honk.'],
        ['Mabel', 'Then why is it asking to see the wine list?', 'surprised'],
        ['Narrator', 'Ravi brought two lists. The goose looked like it might want dessert.'],
      ],
    },
    {
      title: 'Salt on the Windows', genre: 'Drama', palette: '#5d7251',
      lines: [
        ['Narrator', 'Two days after the storm, the bakery smelled of the sea.'],
        ['Tess', 'The oven still works. I made enough bread for the whole street.'],
        ['Wren', 'Are you going to charge them?'],
        ['Tess', 'Of course. One dry chair each, if they can spare it.', 'quiet'],
        ['Narrator', 'By noon the chairs spilled out onto the pavement. They were all different.'],
      ],
    },
    {
      title: 'The First Flight', genre: 'Adventure', palette: '#5b827c',
      lines: [
        ['Narrator', 'The runway ended where the ice began.'],
        ['Amara', 'That’s half the distance you said we’d have.'],
        ['Leon', 'Then we’ll know twice as soon if it works.'],
        ['Narrator', 'The little plane began to move.'],
      ],
    },
    {
      title: 'Secondhand Stars', genre: 'Science fiction', palette: '#484d8a',
      lines: [
        ['Narrator', 'Bea set a blue star on the counter. It still gave off a little heat.'],
        ['Bea', 'Will you take it back without a receipt?'],
        ['Merchant', 'Depends which part of the galaxy you took it from.'],
        ['Narrator', 'She turned the star over so he could see the initials.'],
      ],
    },
    {
      title: 'Above the Bookshop', genre: 'Mystery', palette: '#8c6745',
      lines: [
        ['Narrator', 'At midnight, books began sliding across the floor upstairs.'],
        ['Lena', 'Should I call the owner?'],
        ['Sami', 'You bought the shop last Tuesday.'],
        ['Narrator', 'She had been hoping he wouldn’t remember that.'],
      ],
    },
    {
      title: 'The Garden Key', genre: 'Fantasy', palette: '#587a5c',
      lines: [
        ['Narrator', 'Jules pressed the key into the soil beside the rosebush.'],
        ['Ren', 'How long before it grows?'],
        ['Jules', 'About as long as it takes to forget what it opens.'],
        ['Narrator', 'By morning, a door stood between the cabbages.'],
      ],
    },
    {
      title: 'Tuesday at the Museum', genre: 'Comedy', palette: '#8a563f',
      lines: [
        ['Narrator', 'The portrait coughed just as the museum closed.'],
        ['Guard', 'You again. Is something wrong with the lighting?'],
        ['The duke', 'I’d like a book. I have been holding this one upside down since 1764.'],
        ['Narrator', 'The guard set off to find the librarian.'],
      ],
    },
    {
      title: 'One Seat Left', genre: 'Romance', palette: '#8a526d',
      lines: [
        ['Narrator', 'Someone had saved the aisle seat with a scarf.'],
        ['Sofia', 'I thought you weren’t coming.'],
        ['Ari', 'I came early. I didn’t know which seat you’d want.'],
        ['Narrator', 'She wrapped the scarf around her neck and sat down.'],
      ],
    },
    {
      title: 'The Quiet Signal', genre: 'Thriller', palette: '#49657b',
      lines: [
        ['Narrator', 'The emergency radio clicked twice and fell quiet.'],
        ['Devi', 'That means stay inside.'],
        ['Cal', 'We’re already outside.'],
        ['Narrator', 'Devi pointed at the shuttered station across the road. The radio clicked again.'],
      ],
    },
    {
      title: 'A Place at the Table', genre: 'Drama', palette: '#7a6942',
      lines: [
        ['Narrator', 'There was one extra plate, as there had been every Sunday since spring.'],
        ['Malik', 'Should I clear it away?'],
        ['Grace', 'Leave it for now. Your brother knows where the spare key is.'],
        ['Narrator', 'She took the bread out of the oven as someone knocked.'],
      ],
    },
    {
      title: 'The Fog Bell', genre: 'Adventure', palette: '#547069',
      lines: [
        ['Narrator', 'The fog swallowed the dock before the boat was halfway across.'],
        ['Captain Rosa', 'Listen for the bell.'],
        ['David', 'I hear two. Which one is ours?'],
        ['Narrator', 'Then both bells stopped, and the tide began to turn.'],
      ],
    },
  ];

  const delivery = { quiet: { rate: 0.9, volume: 0.76 }, surprised: { rate: 1.08, volume: 1 } };

  window.mountShowcase = function (root) {
    if (!root || root.dataset.showcaseMounted) return;
    root.dataset.showcaseMounted = 'true';
    root.classList.add('voice-showcase');
    root.innerHTML = `
      <div class="voice-showcase__header">
        <a class="voice-showcase__link" data-link>Open sample ↗</a>
        <div class="voice-showcase__nav" aria-label="Sample navigation">
          <button class="voice-showcase__arrow" type="button" data-prev aria-label="Previous sample">‹</button>
          <span data-position></span>
          <button class="voice-showcase__arrow" type="button" data-next aria-label="Next sample">›</button>
        </div>
      </div>
      <div class="voice-showcase__card" aria-roledescription="slide" role="group">
        <div class="voice-showcase__story">
          <span class="voice-showcase__genre" data-genre></span>
          <h3 data-title></h3>
          <div class="voice-showcase__controls">
            <button class="voice-showcase__play" type="button" data-play aria-label="Play sample" title="Play sample"></button>
            <div class="voice-showcase__progress">
              <input type="range" min="0" value="0" step=".1" data-seek aria-label="Seek in this sample">
              <span data-time aria-label="Estimated playback time"></span>
            </div>
          </div>
          <p class="voice-showcase__status" data-status role="status" hidden></p>
        </div>
        <ol class="voice-showcase__transcript" data-lines aria-label="Sample transcript"></ol>
      </div>
    `;

    const parts = Object.fromEntries(
      ['prev', 'next', 'position', 'genre', 'title', 'play', 'seek', 'time', 'status', 'lines', 'link']
        .map(name => [name, root.querySelector(`[data-${name}]`)]),
    );
    const card = root.querySelector('.voice-showcase__card');
    const speech = typeof window.SpeechSynthesisUtterance === 'function' ? window.speechSynthesis : null;
    let sampleIndex = 0;
    let lineIndex = 0;
    let utterance = null;
    let playing = false;
    let finished = false;
    let speakerVoices = new Map();
    let offsets = [0];
    let elapsed = 0;
    let runningFrom = 0;
    const slug = (sample) => sample.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '');
    const formatTime = (seconds) => Math.floor(seconds / 60) + ':' + String(Math.floor(seconds % 60)).padStart(2, '0');

    function position() {
      const time = elapsed + (runningFrom ? (performance.now() - runningFrom) / 1000 : 0);
      return Math.min(finished ? offsets.at(-1) : offsets[lineIndex + 1] ?? 0, time);
    }

    function updateTime() {
      const value = position();
      const duration = offsets.at(-1);
      parts.seek.value = value;
      parts.seek.style.setProperty('--voice-progress', (duration ? value * 100 / duration : 0) + '%');
      parts.time.textContent = formatTime(value) + ' / ' + formatTime(duration);
    }

    function setStatus(message) {
      parts.status.hidden = !message;
      parts.status.textContent = message;
    }

    function updatePlayback() {
      const label = playing ? 'Pause sample' : utterance ? 'Resume sample' : 'Play sample';
      parts.play.dataset.playing = String(playing);
      parts.play.setAttribute('aria-label', label);
      parts.play.title = label;
      updateTime();
      Array.from(parts.lines.children).forEach((row, index) => {
        const button = row.firstElementChild;
        if (lineIndex === index) button.setAttribute('aria-current', 'true');
        else button.removeAttribute('aria-current');
      });
    }

    function cancelUtterance() {
      if (!utterance) return;
      utterance = null;
      speech.cancel();
      if (speech.paused) speech.resume();
    }

    function stop() {
      elapsed = position();
      runningFrom = 0;
      playing = false;
      cancelUtterance();
      updatePlayback();
    }

    function displaySample(next) {
      stop();
      sampleIndex = (next + samples.length) % samples.length;
      lineIndex = 0;
      elapsed = 0;
      finished = false;
      const sample = samples[sampleIndex];
      offsets = [0];
      for (const [, text, tone] of sample.lines) {
        offsets.push(offsets.at(-1) + text.split(/\s+/).length * .39 / (delivery[tone]?.rate || 1));
      }
      const speakers = Array.from(new Set(sample.lines.map(([speaker]) => speaker)));
      speakerVoices = new Map(speakers.map((speaker, index) => [speaker, index]));
      card.style.setProperty('--voice-color', sample.palette);
      card.setAttribute('aria-label', `${sample.title}, sample ${sampleIndex + 1} of ${samples.length}`);
      parts.position.textContent = `${sampleIndex + 1} / ${samples.length}`;
      parts.genre.textContent = sample.genre;
      parts.title.textContent = sample.title;
      parts.link.href = '/?sample=' + slug(sample) + '#performances';
      parts.seek.max = offsets.at(-1);
      parts.lines.replaceChildren(...sample.lines.map(([speaker, text], index) => {
        const row = document.createElement('li');
        const button = document.createElement('button');
        const name = document.createElement('span');
        const line = document.createElement('span');
        button.type = 'button';
        name.className = 'voice-showcase__speaker';
        name.textContent = speaker;
        line.textContent = text;
        button.append(name, line);
        button.addEventListener('click', () => {
          if (speech) start(index);
          else seek(index);
        });
        row.append(button);
        return row;
      }));
      setStatus(speech ? '' : 'Your browser does not support sample playback.');
      updatePlayback();
    }

    function speakLine() {
      const lines = samples[sampleIndex].lines;
      const [speaker, text, tone] = lines[lineIndex];
      const voiceIndex = speakerVoices.get(speaker);
      const voice = new window.SpeechSynthesisUtterance(text);
      const available = speech.getVoices();
      const english = available.filter(candidate => /^en(?:-|_|$)/i.test(candidate.lang));
      const voices = english.length ? english : available;
      const style = delivery[tone] || { rate: 1, volume: 1 };
      if (voices.length) voice.voice = voices[voiceIndex % voices.length];
      voice.lang = voice.voice ? voice.voice.lang : 'en-US';
      voice.pitch = [1, 1.12, 0.9][voiceIndex] || 1;
      voice.rate = style.rate;
      voice.volume = style.volume;
      utterance = voice;
      elapsed = offsets[lineIndex];
      runningFrom = performance.now();
      voice.onend = () => {
        if (utterance !== voice) return;
        utterance = null;
        if (lineIndex + 1 < lines.length) {
          lineIndex += 1;
          speakLine();
        } else {
          finished = true;
          playing = false;
          elapsed = offsets.at(-1);
          runningFrom = 0;
        }
        updatePlayback();
      };
      voice.onerror = () => {
        if (utterance !== voice) return;
        utterance = null;
        elapsed = position();
        runningFrom = 0;
        playing = false;
        setStatus('Playback is unavailable. Try another browser or check your speech settings.');
        updatePlayback();
      };
      speech.speak(voice);
    }

    function start(index) {
      window.dispatchEvent(new Event('voiceemo:showcase-play'));
      cancelUtterance();
      setStatus('');
      lineIndex = index;
      elapsed = offsets[index];
      finished = false;
      playing = true;
      updatePlayback();
      speakLine();
    }

    function seek(index) {
      if (playing) {
        start(index);
        return;
      }
      cancelUtterance();
      lineIndex = index;
      elapsed = offsets[index];
      runningFrom = 0;
      finished = false;
      updatePlayback();
    }

    parts.prev.addEventListener('click', () => displaySample(sampleIndex - 1));
    parts.next.addEventListener('click', () => displaySample(sampleIndex + 1));
    parts.play.disabled = !speech;
    parts.play.addEventListener('click', () => {
      if (playing) {
        elapsed = position();
        runningFrom = 0;
        playing = false;
        speech.pause();
      } else if (utterance) {
        playing = true;
        runningFrom = performance.now();
        speech.resume();
      } else {
        start(finished ? 0 : lineIndex);
      }
      updatePlayback();
    });
    parts.seek.addEventListener('change', () => {
      const time = Number(parts.seek.value);
      const index = offsets.findIndex((offset, i) => i && time < offset) - 1;
      seek(index < 0 ? offsets.length - 2 : index);
    });
    setInterval(() => { if (playing && utterance) updateTime(); }, 250);
    window.addEventListener('voiceemo:studio-play', stop);
    const requested = new URLSearchParams(window.location.search).get('sample');
    displaySample(Math.max(0, samples.findIndex((sample) => slug(sample) === requested)));
  };
})();
