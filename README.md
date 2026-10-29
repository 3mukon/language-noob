# Language Noob

Language Noob is a macOS vocabulary learning application for English and Japanese. Study in a stack of paper-style cards or in the terminal, with shared local vocabulary and learning progress.

## Status

The local desktop application and command-line client target macOS 14 or later. They provide English and Japanese study, due-first SM-2 review, local JSON import and search, persistent learning statistics, and temporary card-local AI follow-ups.

## Product direction

- macOS 14 or later is the only officially supported platform. The local build is verified on Apple Silicon.
- Use the graphical interface or the optional terminal client, with English and Japanese kept separate.
- The UI and UX copy use Simplified Chinese. Words and example sentences retain their English or Japanese text.
- Swipe left for the next card and right for the previous card, with equivalent keyboard and native-menu controls.
- Word cards keep a fixed size and retain real vocabulary content throughout the stack. Follow-up questions live on a smaller note attached to the current card; its text and controls stay upright within the tilted paper, and its content scrolls independently without resizing the word cards.
- Follow-up context belongs to a card within the current study session. Returning to that card during the session retains its temporary conversation; a new encounter starts with fresh context. Conversations are not persisted.
- AI follow-ups stream through locally authenticated Codex or Claude, or an explicitly configured Messages API or Responses API. API settings accept a model, base URL and key; keys stay in macOS Keychain, scoped to the chosen endpoint. Automatic selection uses only local services. Offline study remains available when a provider is missing or unavailable.

## Quick start

Already installed? Open **LanguageNoob** in Applications, or start a terminal round from any directory:

```sh
language-noob study
```

This uses the saved language and combines new words with due reviews. Running `language-noob` without a command shows help. First-time installation is described below; no one-command installer or prebuilt release is provided yet.

### Build from source

Use macOS 14 or later with Git, Bash, Python 3.9+, Swift 6.4 and a macOS 14 or newer SDK. Apple Command Line Tools provide the compiler and SDK; install them with `xcode-select --install` if needed. WebKit checks require an unlocked graphical session and briefly open test windows. Node.js enables the additional JavaScript syntax checks; commit checks and CI require Gitleaks 8.30.1.

```sh
git clone https://github.com/3mukon/language-noob.git
cd language-noob
sh scripts/check.sh
```

The check builds and tests both clients, including shared learning logic, native WebKit rendering and packaged terminal processes. It produces `dist/LanguageNoob.app` and the complete `dist/language-noob/` terminal package. Tests use disposable data and a fake streaming service; no API key is needed.

### Install the desktop app

Open `dist` in Finder and **move** `LanguageNoob.app` into `/Applications`. For an update, quit the installed application first and replace its existing bundle. Launch the installed copy from Applications. Keeping and launching another `.app` in the build directory can create a second entry in the macOS application list.

### Install the terminal command

For a first installation, run these commands from the cloned repository:

```sh
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
mv dist/language-noob "$HOME/.local/share/"
ln -s "$HOME/.local/share/language-noob/bin/language-noob" "$HOME/.local/bin/language-noob"
```

Move the entire package: `bin`, `lib`, `Resources` and `LICENSE` must stay together. For an update, exit running terminal rounds and move the previous `~/.local/share/language-noob` directory aside as a backup before moving in the new package. Keep the existing command symlink when it already points to the installation location.

If `~/.local/bin` is not already on PATH, add the following line once to `~/.zshrc`, then open a new terminal. Running the line directly also enables the command in the current shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Verify with `language-noob --help`. The command also works by its full path, `~/.local/bin/language-noob`, without changing PATH.

### Everyday terminal commands

```sh
language-noob study --lang en       # New English words and due reviews
language-noob study --lang ja       # New Japanese words and due reviews
language-noob learn                 # Only new words, using the saved language
language-noob review                # Only due reviews, using the saved language
language-noob search music --lang en
language-noob stats --lang en --json
language-noob config show --effective
language-noob --help
```

Inside a round, enter `help` for available actions, `next` or `prev` to navigate, `reveal` to see an answer, and `quit` to exit. Reading and navigation never record a grade. `--lang en` and `--lang ja` apply to that command only; `language-noob config set language ja` changes the saved language. See the [CLI module](Sources/LanguageNoobCLI/README.md) for grading, questions, cancellation and configuration details.

### Data and updates

Both clients share `~/Library/Application Support/Language Noob`: vocabulary, saved enrichment, progress and ordinary AI settings. Replacing the program packages preserves that directory. API keys remain in macOS Keychain. Pass `--data-directory <directory>` for isolated data. New commands read the latest saved data; already-open rounds retain their own temporary state and conversations.

## Study flow

New words first appear as reading cards, followed by recall cards. Due reviews use assessment cards directly. Try to recall the answer, reveal it, then choose a grade; only that explicit assessment saves progress. The next round samples new words randomly, with English and Japanese kept separate. Ending a round retains completed grades and clears its temporary conversations.

Navigation preserves unfinished work. Library searches open a separate stack of matching entries; returning to study restores its position and temporary notes. Switching languages within the library retains the search panel, query and input focus, and refreshes only the selected language. Drag the library header to move the window. Adding a word reuses unfinished assessments when possible. Reading and browsing never save a grade; explicit grades are saved before the interface advances. Existing version-1 learning databases remain compatible.

AI is optional. Choose the application's AI settings or terminal `config` commands to use an authenticated local Codex/Claude Code installation or an API endpoint. Both local and API connections stream replies. Automatic mode discovers local services and inherits their model settings; choosing an explicit connection enables overrides. Without a usable service, offline vocabulary and study remain available. API keys are entered through the native settings dialog or the terminal's hidden `config key set` prompt.

## Bundled dictionaries

Both dictionaries are included for offline use and selected automatically by the study language.

| Language | Source | Included entries | Contents and attribution |
|---|---|---:|---|
| English | [ECDICT](https://github.com/skywind3000/ECDICT) | 12,126 selected headwords | Pronunciation, Chinese meanings, localized parts of speech and difficulty/examination tags. Source distributed under MIT. |
| Japanese | [JLPT Vocabulary](https://github.com/Bluskyo/JLPT_Vocabulary), converted from [Jonathan Waller's JLPT Resources / Tanos](https://www.tanos.co.uk/jlpt/) | 8,505 records | Words, readings and JLPT levels; all source records are retained, including five exact repetitions. Original vocabulary is credited under CC BY; the conversion repository uses MIT. |

The Japanese source has no Chinese meanings, parts of speech or example sentences. Missing study content can be generated by the configured AI service and is stored separately from the bundled data. The original Japanese data's attribution does not specify a CC BY version; this project preserves that attribution without assigning a different license.

Pinned upstream revisions, input hashes and counts are recorded in [dictionary-sources.json](Sources/StudyRuntime/Resources/dictionary-sources.json). [DictionaryNotices.txt](Sources/StudyRuntime/Resources/DictionaryNotices.txt) contains the full notices, original source links and transformations; both files ship with the desktop and terminal resources. The application license does not replace these third-party terms. The twelve former examples are migration fixtures, not the default vocabulary.

Each round, search and progress view uses only the selected language. At the start of a round, both clients reuse cached enrichment and queue its unique missing entries for the selected AI service. AI settings control enrichment concurrency from one to eight, defaulting to one; navigation does not restart requests. Successful definitions, readings, parts of speech and examples are saved locally. Unavailable services leave the source data usable; the Study menu and terminal `enrich` command can retry. Saved entries require confirmation before manual regeneration (the terminal uses `enrich --force`). Library searches make no model requests, and the application never translates the entire corpus automatically. Existing imports, AI enrichment and recorded progress are preserved during installation.

## Documentation

Start with the [documentation index](docs/INDEX.md). Architecture rules are in [architecture.md](docs/architecture.md); development and verification conventions are in [conventions.md](docs/conventions.md). All project documentation is written in English, including the glossary and templates.

## Release preparation

The build is an unsigned local development app. Signing, notarization and broader release distribution remain future work.

## License

Language Noob is licensed under the [MIT License](LICENSE), copyright (c) 2026 3mukon. Bundled dictionary data retains the third-party terms and attribution described above.
