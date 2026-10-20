# Whytap — Спецификация продукта

> **Статус 2026-10-18.** Whytap — бесплатный open-source инструмент (MIT),
> только BYOK. Аккаунтов, тарифов и телеметрии нет: STT и LLM работают напрямую
> у провайдера ключом пользователя или на его OpenAI-compatible endpoint;
> локальные модели убраны 2026-10-18
> (`.project-docs/decisions/2026-10-18-remove-local-models.md`). Агент —
> локальный OpenCode с моделью пользователя через OpenRouter.
> Разделы ниже про roadmap и vocabulary написаны в облачную эпоху и
> сохранены как продуктовый контекст; упоминания backend/подписки в них не
> актуальны. См. `docs/plans/2026-09-02-fully-local-open-source.md`.

> Версия 3. Базовая продуктовая версия — 2026-05-09; освежена после
> июньского пивота (агент = локальный CLI пользователя, монетизация =
> STT + meetings). Vision-разделы (vocabulary, artifacts, learning)
> остаются целевыми; «Что уже работает» отражает текущий клиент.

## Позиционирование

**Whytap превращает грязную речь в готовый к работе текст, ссылки и действия — внутри того приложения, в котором ты уже работаешь.**

Не "ещё одна диктовка". Голосовой слой поверх рабочих инструментов: говоришь как думаешь, а в Slack, Linear, Notion, GitHub, Cursor попадает уже готовое сообщение, тикет, промпт или артефакт — с правильным языком, стилем, ссылками и контекстом.

## Главный UX-принцип: приложение невидимо

Пользователю **не нужно ничего изучать**. SuperWhisper открывает огромное окно с настройками — у нас наоборот:

- Никаких больших окон с настройками
- Никакой админки и панелей управления
- Никакого onboarding-туториала
- Только маленькая плашечка справа снизу, которая всё делает за пользователя

Пользователь открыл приложение → увидел плашечку → начал работать. Всё. Никаких вопросов, никакого «как этим пользоваться». Любые настройки появляются только когда они нужны прямо сейчас и в минимально возможной форме (chips/labels в самой плашечке, не отдельные окна).

## Целевая аудитория

Knowledge workers — разработчики, продакт-менеджеры, операционщики. Стартовая аудитория: наша команда и круг (стек Slack, Linear, Notion, GitHub, Cursor).

## Что уже работает

- macOS 14.2+, Swift + AppKit + SwiftUI; surface — Dynamic Island (status-bar item нет)
- Voice flow: hold Space (удержание пробела в редактируемом поле; Escape — отмена) → запись → realtime STT: «Your key» (Soniox / Deepgram / ElevenLabs / self-hosted OpenAI-compatible, напрямую ключом пользователя из Keychain) → cleanup (OpenRouter ключом пользователя / custom OpenAI-compatible endpoint / без LLM) → Cmd+V
- Agent flow: Right Cmd tap/hold → локальный OpenCode → выбранная пользователем модель OpenRouter, рендер в окне
- Meeting Notes: always-on детектор → запись (mic + system audio) → BYOK-процессор (Soniox размечает спикеров, саммари — LLM пользователя) → notes window
- App-aware форматирование (Notion/Linear/Slack/Telegram → markdown, остальное → plain)
- Без аккаунта, без серверов Whytap, без телеметрии
- Sparkle auto-update (download-on-action, pill в Dynamic Island), фид — GitHub Releases
- Bundle `com.rootwise.sidekey`
- Репозиторий: [AbsoluteMode/whytap](https://github.com/AbsoluteMode/whytap)
- Hover: выбранные пользователем инструменты рядами по три, только иконка и название без мелких подписей состояния; у Record во время записи загорается красная иконка, индикатор записи в правом крыле сохраняется. Состояния доступны VoiceOver. Поиск по всему каталогу запускает редкий инструмент (например Output Lang), не добавляя его в постоянные кнопки.
- Display — яркость (hover, из каталога и поиска): белый ползунок подсветки экрана с островом, свитч Extra (постоянный EDR-буст поверх текущей яркости через таблицу дисплея, как у Vivid, только на дисплеях с запасом яркости; любое снижение яркости выключает Extra, включая автояркость и затемнение при бездействии; изменения macOS отслеживаются раз в полсекунды и при закрытой панели, повышение яркости не включает Extra; выключает также свитч, перегрев, смена дисплея или потеря им EDR, другое приложение, меняющее таблицу дисплея (например Vivid), и выход) и строка с оставшимся временем работы от батареи: по заряду, средней нагрузке за последние полчаса и текущей яркости, с пересчётом при каждом изменении яркости и Extra. Свитчи Extra и Brightness keys есть и в Settings → Toolbox → Display. Brightness keys (по умолчанию выключены): клавиши яркости Mac показывают полоску в острове вместо системного индикатора, два нажатия «ярче» на максимуме включают Extra. Всё локально; сохраняется только переключатель клавиш.

---

Whytap — новое имя Whytap. Bundle ID, Keychain и пути локальных данных
сохранены для совместимости с существующими установками.

Notify: карточки слева от острова, постоянная история с цветом и логотипом
события. Пользовательский агент настраивает локальные скрипты-источники; Whytap
запускает их на время работы приложения. Settings → Notifications показывает
подключённые источники и позволяет отключать и включать каждый отдельно,
сохраняя настройку и историю. «Notification type»: Large — карточка слева;
Small — иконка без текста поверх всего правого крыла (хинты, встречи, музыка).
Маленькая иконка слегка потряхивается и исчезает через 5 секунд по умолчанию;
наведение приостанавливает таймер, увеличивает иконку и показывает крестик рядом.
Нажатие открывает ссылку события, крестик закрывает его; история сохраняется.
Серия Small собирается в стопку со счётчиком: до трёх иконок видны, при наведении
они слегка разъезжаются, каждая открывает свою ссылку. Новое событие начинает
таймер стопки заново; по истечении времени исчезает вся стопка. Large сохраняет
порядок очереди и разделяет серии. История хранит 500 последних событий.
На Notify в hover и поиске горит красная точка до открытия истории; она сохраняется
после исчезновения иконок и перезапуска. Monitor не подсвечивается. Clear All
показывается без иконки и сразу очищает историю и текущие уведомления без
подтверждения; источники остаются подключены.
При Reduce Motion нет тряски и увеличения. [Контракт](customization/notifications.md).

## Backup

Settings → Backup: локальная зашифрованная история настроек и ключей, возврат
отдельного блока к сохранённой версии или source defaults. Облачная копия
опциональна: приватный Exodia-Backup в GitHub пользователя либо выбранная
папка. Один код восстановления сохраняется вне Whytap и проверяется обратной
вставкой. В архив входят текущие настройки, ключи провайдеров, Case, встречи,
сохранённые изображения и рабочие файлы приложения; внешние ссылки не
подменяются обещанием сохранения оригиналов.

Основной экран: **Back up** и **Restore backup**. Управление бэкапом и локальная
история настроек раскрываются отдельно. **Change code** требует сохранить новый
код, затем создаёт и проверяет независимую полную копию перед удалением прежних
полных копий на Mac и в подключённом хранилище. **Delete backups** удаляет эти
копии и выключает автобэкап без сохранения нового кода; рабочие данные и локальная
история остаются. Незавершённая операция хранится на диске и возобновляется с
автобэкапом на паузе. Скачанные копии нельзя отозвать; другие хранилища, облачная
корзина/история и автобэкап на других Mac требуют отдельного действия пользователя.

На новом Mac: подключить источник, ввести код, проверить версию и выбрать
данные. Изменения применяются при следующем обычном запуске; чужие задания
и скрипты не запускаются автоматически. Бэкап не объединяет параллельные
изменения с разных Mac. [Инструкция](backup.md).

## Roadmap

Далее сохранён исторический roadmap. Упоминания Whytap, старых CLI и облачной
архитектуры описывают прежние решения; актуальный агент описан в
[README](../README.md). Раздел Projects и подстановка проектных знаний
[удалены](../.project-docs/decisions/2026-10-19-remove-projects.md).

### Milestone 1 — Диктовка, которой можно доверять

**Цель:** пользователь делает 30-100 вставок в день, ни разу не подумав "проще было напечатать".

| Фича | Описание |
|------|----------|
| Output language | Куда вставлять (русский, английский, …) |
| Input language / auto | На каком говорим |
| App-aware formatting | Уже есть, дорабатываем под целевые приложения |
| Manual vocabulary | Для bootstrap, до auto-learning |
| Voice Clipboard | Последние 20-50 результатов: поиск, copy, re-run, edit, delete (вместо "архив всех записей") |
| **Voice Edit** | Единая фича работы с текстом в области курсора. Если есть выделение — работаем с выделением, иначе — со всем содержимым поля. AX читает текст, LLM правит, заменяет. Use cases: перевод ("переведи на английский" — наш USP, лучше DeepL за счёт technical vocabulary + screen context), стиль ("сделай короче"), редактирование поля ("замени X на Y", "добавь приветствие"). Edit chip появляется когда курсор в text field с содержимым, скрывается через AX observers (focus change / app switch / value clear) — без таймера. **Cmd+Z отменяет правку.** |
| **Tool hotkeys** | Settings → Hotkeys binds named catalog functions, including unpinned tools. Reordering tiles preserves bindings; users can record or remove each optional shortcut. Saved legacy position shortcuts migrate once. |
| **Customizable hotkeys** | Пользователь может переназначить любой хоткей: диктовка, edit, ask mode. Дефолт `Right Option + /`, `Right Option + .` и т.п. |
| Screenshot gating | Скриншот не всегда — только когда есть deictic words ("вот это", "там"), high-context app или low confidence по терминам |
| Native macOS distribution | Открытые исходники и готовые community-сборки без Apple Developer. Обновления через Sparkle с нашей Ed25519-подписью; перезапуск откладывается при активной записи, диктовке или работе агента. Кастомные source-сборки обновляются отдельно. |
| Basic eval suite | p95 latency, correction rate, edit distance after paste |

**Метрики успеха M1:**
- p95 latency на вставку
- Edit distance пользователя после нашей вставки
- Dictations per active user per day
- 7-day retention
- "Would you be upset if this disappeared?" survey

### Milestone 2 — Рабочий контекст

**Цель:** Whytap вставляет не просто текст, а текст с правильными ссылками, цитатами и тикетами.

| Фича | Описание |
|------|----------|
| **Artifact Suggestions** | Параллельный pipeline ищет связанные артефакты в Slack/Linear/Notion/GitHub. **НЕ вставляет** в текст — показывает как chip-карточки под полем ввода с превью и кнопкой attach. Пользователь сам прикрепляет нужное. |
| Anchored search only | Поиск артефактов **только при наличии якоря**: выделение, активный канал, URL вкладки, Linear/PR на экране, последнее скопированное, явное имя. Без якоря — не угадываем. |
| Slack channel/thread context | Знаем где ты сейчас в Slack |
| Linear issue detection | Из URL вкладки или скриншота |
| GitHub PR/repo/branch context | Из URL или активного редактора |
| Notion page context | Из URL вкладки |
| Auto workspace vocabulary | Словарь из Slack/Linear/Notion/GitHub: термины, люди, проекты, репозитории, ветки, тикеты + произносительные alias ("локейт" → Lokate) |
| Per-recipient style memory | С этим человеком — формально по-английски, в этот канал — коротко, в Telegram — casual |
| Artifact cards в Voice Clipboard | Видно какие артефакты были использованы и почему |
| Confidence thresholds | Низкая уверенность — не подмешиваем артефакт, лучше без него |

### Milestone 3 — Ask Mode (Connect Claude / Codex)

**Цель:** голосовой/текстовый ассистент поверх рабочего контекста. После
июньского пивота «мозг» — собственный локальный agent-CLI пользователя
(Claude Code или Codex), запущенный на его машине под его логином: его
подписка, его MCP-серверы, его память. Whytap = голос+UX; серверного
агента, managed-коннекторов и серверной памяти у нас НЕТ.

**UX-принципы (КРИТИЧНО):**
- **Никаких открытых окон поверх экрана без нужды** — ответ в pill/окне справа снизу
- Pill при ответе расширяется в более крупный bar (минималистичный, не модальное окно)
- Ответ короткий, естественный, с кнопкой copy / open link

**Активация:** Right Cmd (tap — текст, hold — голос).

**Подключение:** Settings → Agents → **Connect Claude Code** / **Connect
Codex**. Одновременно активен один; выбор другого заменяет активного.
Доступ к данным/инструментам определяется конфигом CLI пользователя
(его MCP-серверы), а не нами.

**Примеры (зависит от MCP пользователя):**

| Запрос | Как отвечает |
|--------|-------------|
| "Когда у меня следующая встреча?" | "В Antline с Сашей через полчаса" + кнопка open in Calendar |
| "Сева мне поставил задачу — какая?" | Ссылка на LIN-234 с заголовком + open |
| "Что в #product за последний час?" | 1-2 строки summary + open thread |
| "Какой PR у меня сейчас в работе?" | Имя PR + open в GitHub |
| "Что в README этого проекта про авторизацию?" | Цитата + open |

Safety и write-actions — на стороне CLI пользователя и его tool-permission
модели; Whytap их не проксирует и не хранит.

---

## Vocabulary architecture

> *Vision-раздел: архитектура продумана, не реализована. После пивота
> Whytap НЕ держит серверных коннекторов к Slack/Linear/Notion/GitHub —
> рабочий контекст приходит через CLI/MCP пользователя или из экрана.
> Таблица «Источники» ниже — целевая модель, а не текущая sync-инфра.*

### Где работает vocab

На **обоих** этапах pipeline, с разной логикой:

| Этап | Размер | Зачем | Что включаем |
|------|--------|-------|--------------|
| **Transcribe** (STT-промпт) | ~30 терминов | Чтобы STT правильно **расслышал** слово | Канонические термины + произносительные aliases ("Lokate; локейт; локате") |
| **Verify** (cleanup-промпт) | ~100-150 терминов | Чтобы LLM **исправил написание** + нормализовал | Только канонические формы |

Двухступенчатый ranking — до транскрипции (только app/screenshot) и после (+ raw text как сигнал).

### Источники

| Источник | Что забираем | Sync |
|----------|--------------|------|
| Slack | Каналы, люди, термины из сообщений | Initial pull 30 дней + events API |
| Linear | Проекты, тикеты (LIN-XXX), assignees, labels | GraphQL pull + webhook |
| Notion | Заголовки страниц, теги, базы | Initial pull + polling |
| GitHub | Repos, branches, PR, files, people | API pull + webhook |
| Screenshot OCR | Редкие слова из активного окна | On-fly при low confidence |
| User edits | Что правил после нашей вставки | Local diff loop |
| Manual | Через Settings | Bootstrap |

### Хранилище

Local SQLite. Минимальная структура: `term`, `aliases[]`, `source`, `frequency`, `last_seen`, `embedding`, `app_affinity`, `is_core`, `user_confirmed`.

### Ranking

```
score(term) =
    embedding_similarity(term, context) * 0.4 +
    app_affinity[active_app]            * 0.25 +
    log(frequency)                      * 0.15 +
    recency_decay(last_seen)            * 0.10 +
    user_confirmed_boost                * 0.10
```

Контекст: активное приложение + screenshot + selection + последняя вставка + (после транскрипции) raw text.

### Pronunciation aliases

| Способ | Когда |
|--------|-------|
| Auto-generation | LLM генерирует русские варианты при добавлении |
| Explicit user rule | "запомни локейт это Lokate" |
| Edit-driven | Поправил Spherix → Sferyx — добавляем alias |
| Acronym pattern | LIN-234 → "лин 234" |

### Embeddings

- **Старт:** OpenAI `text-embedding-3-small` (~$0.02 / 1M токенов)
- **Будущее:** локально через MLX/Foundation Models — privacy + no cost

### Privacy gates

- Per-source opt-in (Slack/Linear/Notion/GitHub отдельно)
- Per-channel denylist
- DM не индексируем по умолчанию
- Приватные каналы только с opt-in
- Clear vocabulary — полный сброс
- Private mode — выключает auto-vocabulary на сессию

### Открытые вопросы по vocab

1. **Embedding cost vs latency** — в реальном времени embed нового термина или batch?
2. **Cold start** — что делать в первые часы пока auto-vocab не заполнен?
3. **Cross-workspace conflicts** — два workspace с разными значениями одного термина?
4. **Decay strategy** — когда удалять давно не виденные термины?
5. **Delivery** — реализуем сами или поверх готовых решений (sqlite-vec, MLX)?

---

## Архитектура pipeline

```
audio
  ↓
realtime transcribe (backend-хаб /api/transcribe/stream/v2, провайдер
  на сервере) ИЛИ BYOK direct (Your key → провайдер напрямую)
  ↓
intent / context router
  ↓                    ↓
optional context pack  voice action on selection
  - active app         (если хоткей selection)
  - selected text
  - URL вкладки
  - screenshot (gated)
  - vocabulary
  - artifacts (anchored)
  ↓                    ↓
compose / cleanup      (backend; модель не фиксируется в спеке)
  ↓
paste / replace
  ↓
correction & learning loop
```

**Режим Drop фиксируется в начале записи.** Fast вставляет транскрипт с
фильтром слов-паразитов и не обращается к LLM. Smart вставляет только результат
обработки выбранной LLM. Если обработка недоступна, завершилась ошибкой или
вернула пустой текст, островок показывает ошибку Smart и Retry; сырой текст
автоматически не вставляется. Транскрипт остаётся в памяти до успешного Retry,
новой записи или выхода. Retry сохраняет исходные режим и приложение-цель;
смена режима относится к следующей записи. Правило действует и для batch
recovery, и для восстановления по частичному транскрипту.

**Настройки API & Models (Settings → API & Models):** вкладка из двух блоков.
*API keys* — прямоугольные чипы провайдеров без цветных индикаторов (статус
ключа — «Key works», «Limited key», «Key not accepted» и т. п. — во всплывающем
окне чипа) и «Add key»: Soniox, Deepgram, ElevenLabs, OpenRouter,
Anthropic (только для строки Agent) и свои OpenAI-compatible серверы. Ключи
лежат в Keychain, на экран не возвращаются; проверка ключа — бесплатный запрос
к провайдеру. *Models* — по строке на функцию, в строке выпадашка «Provider · model-id» на
каждый её маршрут: Drop Fast (real-time), Drop Smart (real-time + LLM очистки),
Meetings (recorded + LLM заметок), Agent (LLM with tools), Agent voice и Voice
search (real-time), Translation (LLM) и Subtitles audio (real-time). Над карточкой — тихая пометка «N features have no model ·
Show»: Show прокручивает к ним и на пару секунд подсвечивает их строки. В меню модели — только ID модели (короткая
пометка вроде «with speakers» в той же строке); неподходящие модели не
показываются. У Deepgram в меню только модели, обновлённые за последние 12
месяцев (дата — по самой новой `version` в каталоге), плюс вшитые и выбранная;
каталог при этом полный, маршрут на старой модели работает. У строки на OpenRouter есть второе меню — провайдер: Auto
(выбирает OpenRouter, для диктовки — по скорости) или один провайдер модели,
закреплённый без подмены (`provider.order` + `allow_fallbacks: false`, так же
для агента в конфиге OpenCode). У каждого провайдера — медианная задержка до
первого токена и скорость (ток/с) за 30 минут из
`GET /models/{id}/endpoints` с ключом OpenRouter; без цифр — прочерк. Новая
модель начинается с Auto. Модель каждой фичи читается при каждом вызове;
Whytap сам не меняет ни модель, ни провайдера. Статус показывается в строке
только при проблеме (Not verified, Deprecated alias, Removed by provider, Not
supported yet, Key problem, Not set). Каталоги моделей подтягиваются у
провайдера и кэшируются на сутки; новая модель вне вшитого реестра проходит
синтетическую пробу при выборе и по Check now. Первый запуск новой сборки
переносит прежние выборы в маршруты фич и не трогает старые ключи
UserDefaults. Спека — [docs/specs/api-and-models.md](specs/api-and-models.md),
решение —
[2026-10-19-api-and-models](../.project-docs/decisions/2026-10-19-api-and-models.md).

**STT-провайдеры (Your key, выбор пользователя в Settings → API & Models для
каждой фичи):** Soniox (`stt-rt-v5`, по умолчанию), Deepgram (`nova-3`),
ElevenLabs (`scribe_v2_realtime`) или self-hosted endpoint с протоколом OpenAI
Realtime (модель вводит пользователь, по умолчанию `gpt-4o-transcribe`). Сам
OpenAI не предлагается: сохранённый выбор OpenAI читается как Soniox. Drop —
realtime streaming, не batch; заметки встреч с Soniox идут через file API
(`stt-async-v5`).

**Input language** — отдельный от Smart Output language выбор. Явный язык
передаётся STT-провайдеру: Soniox получает мягкие hints с добавлением английского,
Deepgram — `language`, ElevenLabs — `language_code`, self-hosted — поле
`language` совместимого протокола. Deepgram Auto использует `language=multi`:
для `nova-3` это английский, испанский, французский, немецкий, хинди, русский,
португальский, японский, итальянский и нидерландский. Остальные поддерживаемые
языки выбираются явно. Язык ввода общий для всех голосовых фич и выбирается в
островке и в настройках митингов; строка Deepgram в Settings → API & Models
показывает предупреждение, если её модель не подходит к текущему языку.
Неподдерживаемый язык известной Nova-модели и Auto неизвестной сохранённой
модели останавливаются до передачи аудио; Drop открывает API & Models на
строке своей фичи. Сохранённые язык, модель и провайдер сами не меняются.
Realtime и batch используют одну
[политику языков Deepgram](../.project-docs/decisions/2026-10-19-deepgram-language-policy.md).

**Local STT** (FluidAudio Parakeet TDT v3) убран 2026-10-18 вместе с MLX
Qwen и локальной диаризацией. Сохранённый выбор Local не переключается на
провайдера сам: Drop открывает Settings → API & Models, пока пользователь не
выберет провайдера.

**Batch-распознавание** — только запасной путь: деградировавший поток, Retry
после «Couldn't deliver», fallback рекордера и batch-голос агента. Весь take
уходит провайдеру той фичи, что вела Drop (Fast или Smart; для голоса агента —
Agent voice), с его ключом из Keychain и recorded-моделью из вшитого реестра:
Soniox file API (`stt-async-v5`), Deepgram pre-recorded, ElevenLabs
speech-to-text (`scribe_v2`), self-hosted `/v1/audio/transcriptions` на хосте
своего сервера. Без маршрута фичи, ключа или recorded-модели batch недоступен;
другой провайдер не подставляется.

**Screenshot gating (не всегда):**
- Включаем если: deictic words ("вот это", "там", "этот тикет") / high-context app (Slack, Linear, Notion, GitHub, Cursor) / low confidence по терминам / "screen context always" в настройках
- Выключаем если: privacy-denylisted app / sensitive surface на экране / простая диктовка длинного текста

---

## Learning from user edits — три слоя

| Слой | Что делает | Trust level |
|------|-----------|-------------|
| **Explicit correction** | "Запомни: локейт → Lokate", "В Slack делай короче" → memory rule | Высокий |
| **Local diff after last insert** | Только opt-in. Сравниваем то что вставили с тем что осталось через окно времени. Diff → vocabulary candidate. Не читаем весь документ, не логируем поле. | Средний |
| **Reviewable learning inbox** | "Я заметил 4 повторяющиеся правки. Запомнить?" — пользователь подтверждает | Высокий |

**Не делаем:** скрытый keylogger, "мы всё анализируем в фоне".

---

## Privacy as product

Это не юридический текст, а часть UX:

- Per-app privacy denylist — "никогда не скриншотить эти приложения"
- "Never store audio" option
- Encrypted local SQLite для Voice Clipboard
- One-click delete history
- Visible log: что отправлено, куда, зачем
- BYOK («Your key») — STT и LLM напрямую у провайдера ключом пользователя, ключ в Keychain

> Доступ к Slack/Notion/GitHub и т.п. живёт на стороне CLI пользователя
> (его MCP-серверы), не у нас — мы scopes и индексацию не держим.

---

## Meeting Notes

**Live-assistant test preparation (2026-10-19):** Internal opt-in capture uses
the local `sidekey.meetings.liveTestCapture` flag when Meeting Notes uses Soniox.
The user requested no test-mode controls or test-files row in Settings.
It adds a separate live diarization stream, stores private source tracks and
timing locally, and preserves ordinary notes processing. No automatic
suggestions are enabled. Real-call source attribution and latency remain
acceptance tests. See [testing instructions](meeting-assistant-testing.md).

Auto-detect когда пользователь на голосовой встрече (Zoom, Meet, Teams, FaceTime, Discord, Slack huddle и т.п.) и предложить записать структурированную заметку. Whytap уже всегда запущен и имеет JWT — нативное место для этой фичи (vs. Granola/tl;dv как отдельные продукты с собственной авторизацией).

**Signal:** mic-in-use AND speech-in-system-audio (CoreAudio process-tap). Отсекает Whytap-like dictation (нет двусторонней речи) и музыку/видео (нет mic). VAD через FluidAudio (Silero на ANE, macOS 14.2+).

**UX:** nudge «Take notes / Skip» под Dynamic Island с decision window (ignore = decline). После accept — recorder, чанковый upload. Окно «Meetings» (Notion-like editable markdown, BlockNote в WKWebView) открывается из Dynamic Island.

**Backend (`sidekey-meetings-backend`, отдельный Docker контейнер):**
- `POST /meetings/<id>/chunks/<idx>` — resumable upload ~30s WAV
- `POST /meetings/<id>/finalize` — trigger pipeline (concat → Soniox async diarize → LLM summary → markdown)
- `GET /meetings`, `GET /meetings/<id>` — list/view
- `PUT /meetings/<id>/note` — user-edited markdown с 409 conflict detection
- `POST /meetings/<id>/retry` — idempotent retry на failed pipeline

**Privacy invariant:** raw audio удаляется на бэкенде сразу после транскрипции. Transcript + markdown хранятся навсегда. Always-on detector работает только на metadata (mic boolean + system-audio VAD через CoreAudio process-tap) — не записываем content до accept'а.

Подробности — [docs/archive/specs/meetings.md](archive/specs/meetings.md), план реализации — [docs/archive/plans/meetings.md](archive/plans/meetings.md).

---

## Что отложено / не делаем

- **Hover UI** — не приоритет M1. UX живёт в хоткеях, выделениях, последних вставках. Settings — потом.
- **Transcription history "архив всего"** — заменяется Voice Clipboard (последние 20-50, инструмент восстановления и повтора).
- **Серверный agent / managed-коннекторы / серверная память** — выпилены пивотом. «Мозг» = локальный CLI пользователя (Connect Claude / Codex); инструменты и память — на его стороне.
- **Windows версия** — пока только stub-каркас (`windows/`), готового приложения нет. macOS-only до validation.
- **Командное использование** — вырастет из Pro, не отдельный продукт на старте.
- **Полная векторизация Slack/Notion** — не нужна. Артефакты — только при anchor.

---

## Boundaries

### Always
- Хоткей всегда активен
- Наши ключи — только в backend, не в клиенте (BYOK — ключ пользователя в Keychain, direct)
- Pill всегда поверх всех окон, не блокирует ввод
- Скриншоты только активного окна, не весь экран
- ISO-639-1 language hint в STT (улучшает accuracy/latency)

### Never
- Никаких кликов / движений мыши на глазах у пользователя
- Pay-as-you-go для конечных пользователей
- Скриншот без явного триггера или high-context приложения
- Серверный agent / проксирование агента через наш backend (агент = CLI пользователя)
- Хранение audio дольше необходимого (сразу после транскрипции — удаляем)

### Ask
- Конкретная тарифная модель — отдельное исследование
- Backend стек (Cloudflare Workers, Vercel, Fly, custom?)
- Per-recipient style memory — где хранить (локально / облако)?
- Eval suite — какие модельные проверки нужны для p95 latency и correction rate
- Voice Actions on Selection — отдельный хоткей или тот же что и диктовка?

---

## Открытые вопросы

1. **Voice Actions on Selection — хоткей.** Тот же `Right Option+/` (контекст: есть выделение → action mode, нет → dictation), или отдельный?
2. **Backend stack.** Что будем использовать для proxy?
3. **Pricing — конкретные числа.** Нужно market research.
4. **Eval suite.** Какие синтетические и реальные тесты для качества.
5. **Глубина интеграции с CLI-агентом.** Как далеко идём в Connect Claude / Codex (permission-bridge, контекст из экрана), оставаясь вне data/credential-path пользователя.
6. **Streaming vs batch.** Когда переходим на realtime для voice edit preview.

---

## Ближайший шаг

После approval спецификации — план разработки M1 ([writing-plans](docs/plans/) с stages и validation gates).

Самый правильный первый stage M1: **Voice Actions on Selection** + **Edit last insert** + **Voice Clipboard**. Это даст вау быстрее чем любая другая фича.

## Переводчик и субтитры

Translate и Subtitles доступны через поиск инструментов и каталог Toolbox;
у каждого настраивается именованная горячая клавиша. Открывают общее плавающее
окно: текстовый перевод с автонаправлением RU↔EN или явным языком и перевод
системного звука в субтитры с оригиналом. Translation — общая выбранная LLM;
Subtitles audio — отдельная выбранная STT. Оба новых маршрута изначально Not set.
Очереди ограничены; отставание останавливает захват с ошибкой. Закрытие окна,
Cancel и сон завершают захват и запросы; Stop ждёт финальные фразы. Записи и
автоматической истории нет. Подробности и ограничения: [translation.md](translation.md).


## Скриншоты

Screenshot через поиск инструментов/Toolbox открывает захват области; двойной
клик выбирает весь дисплей. Компактная панель: стрелка, фигура, перо, текст,
Blur, отмена, сохранение и копирование. Blur по умолчанию скрывает **текст и
числа**, включая отдельные цифры, локальным Vision; есть режим всей области.
Результат остаётся видимым для проверки. Дополнительные инструменты, OCR,
закрепление, размер и системная отправка находятся в More. Провайдеры/ключи
не нужны; автоматического сохранения и загрузки нет. Подробнее:
[screenshots.md](screenshots.md).
