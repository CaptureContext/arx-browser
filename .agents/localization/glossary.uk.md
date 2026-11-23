# Glossary: Ukrainian (uk)

Translators of Arx into Ukrainian use these terms. A term here wins over any other choice.

## Language rules

- Address: formal "ви", written in lowercase ("ви можете скористатися…"), with plural imperatives ("Перетягніть вікно…"), as Apple's Ukrainian macOS does. Never "ти", never capitalized "Ви". Verified: https://support.apple.com/uk-ua/guide/mac-help/mh14112/mac
- Sources: "verified" rows were checked this session either on Apple's or Google's Ukrainian help pages (URL in Note) or in the Ukrainian string tables that ship with macOS 27.3 on the build Mac: Safari (Safari.app MainMenu and the Safari/WebKit frameworks), AppKit menus, System Settings panes. Note says "Safari", "AppKit" or "System Settings" for those.
- Capitalization: sentence case everywhere: only the first word and proper names are capitalized ("Нове приватне вікно", "Закріпити вкладку"). Apple capitalizes feature names used as names: "Зручне читання", "Читанка", "Робочий стіл".
- Buttons and menu commands: perfective infinitive ("Скопіювати", "Видалити", "Перезавантажити сторінку"), never imperative. Settings checkboxes: imperfective infinitive ("Перевіряти правопис під час введення").
- Punctuation and ellipsis: one character "…" (U+2026), exactly where English has it. Quotation marks: «ялинки», nested „лапки“. Names of apps and settings in running text go in «» ("програма «Паролі»"). Em dash with spaces " — ".
- Apostrophe: Apple writes the modifier letter ʼ (U+02BC): "Обʼєднати", "Вʼязка", "памʼяті". Use it, not ' or ’.
- Apple's Ukrainian vocabulary that differs from Chrome's, and wins: an app is "програма" (not "застосунок"); Settings are "Параметри" (not "Налаштування"); download is "викачати / викачування" (not "завантажити"); install is "інсталювати" (not "встановити"); default is "типово / стандартний"; Delete is "Видалити" but Remove is "Вилучити"; Undo is "Відмінити" but Cancel is "Скасувати"; Share is "Поширити".
- Plural categories: one, few, many, other (1 вкладка, 2 вкладки, 5 вкладок, 1,5 вкладки).
- macOS Spaces: Apple calls them "простори" ("додаткові робочі столи, які називаються простори"), often "простори Spaces" or just "Spaces" in System Settings; Mission Control stays in English. Verified: https://support.apple.com/uk-ua/guide/mac-help/mh14112/mac and System Settings strings ("Пересунути на простір праворуч").
- Arx space: "розділ" (plural "розділи"), because "простір" is Apple's word for macOS Spaces, and "розділ" is a short native word for one page of the sidebar (same choice as Russian "раздел"). Do not use "розділ" for parts of Settings: call those by their name or "група параметрів".
- Icon is "іконка" and a badge on it is "значок" (Apple's Notifications settings: «Значок на іконці програми»). Do not swap them.
- Length: Ukrainian runs 15–30% longer than English; prefer Apple's shorter forms ("Усі наперед", "Оптимізувати") where space is tight.
- Keep in Latin script and never decline: Arx, Little Arx, Peek, Air Traffic Control, Runway, bang, PiP, WebKit, Chromium, MCP, iCloud, Touch ID, Finder, Dock, Mission Control, Split View, Safari, Google, Chrome. Inflect the noun in front instead ("у вікні Little Arx", "у програмі Finder").

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | Файл | menu | verified | no | Safari MainMenu |
| Edit | Редагування | menu | verified | no | Safari MainMenu; as a verb button: Редагувати |
| View | Перегляд | menu | verified | no | Safari MainMenu |
| History | Історія | menu | verified | no | Safari MainMenu |
| Window | Вікно | menu | verified | no | Safari MainMenu |
| Help | Довідка | menu | verified | no | Safari MainMenu |
| Services | Сервіси | menu | verified | yes | Safari MainMenu |
| About Arx | Про Arx | menu | verified | yes | Safari writes "Про Safari" |
| Hide Arx | Сховати Arx | menu | verified | yes | Safari writes "Сховати Safari" |
| Hide Others | Сховати решту | menu | verified | yes | Safari MainMenu |
| Show All | Показати всі | menu | verified | no | Safari MainMenu |
| Quit Arx | Завершити Arx | menu | verified | yes | Safari writes "Завершити Safari" |
| Undo | Відмінити | menu | verified | no | Safari MainMenu; not Скасувати |
| Redo | Повторити | menu | verified | no | Safari MainMenu |
| Cut | Вирізати | menu | verified | no | AppKit |
| Copy | Скопіювати | menu | verified | no | AppKit |
| Paste | Вставити | menu | verified | no | AppKit |
| Paste and Match Style | Вставити і допасувати стиль | menu | verified | yes | AppKit |
| Select All | Вибрати все | menu | verified | yes | AppKit |
| Find | Пошук / Пошук… | menu | verified | no | Edit submenu "Пошук", its item "Пошук…" (Safari) |
| Use Selection for Find | Використати вибране для пошуку | menu | verified | yes | Safari MainMenu |
| Jump to Selection | Перейти до вибраного | menu | verified | yes | Safari MainMenu |
| Spelling and Grammar | Правопис і граматика | menu | verified | yes | Safari MainMenu |
| Show Spelling and Grammar | Показати правопис і граматику | menu | verified | yes | AppKit |
| Check Document Now | Перевірити документ зараз | menu | verified | no | Safari; AppKit shortens to "Перевірити документ" |
| Check Grammar With Spelling | Перевіряти граматику із правописом | menu | verified | yes | AppKit |
| Correct Spelling Automatically | Автоматично виправляти правопис | menu | verified | yes | AppKit |
| Substitutions | Підстановки | menu | verified | yes | Safari MainMenu |
| Smart Links | Динамічні посилання | menu | verified | yes | AppKit |
| Transformations | Перетворення | menu | verified | yes | Safari MainMenu |
| Make Upper Case | У верхній регістр | menu | verified | yes | AppKit |
| Make Lower Case | У нижній регістр | menu | verified | yes | AppKit |
| Capitalize | Великі перші літери | menu | verified | yes | AppKit |
| Minimize | Згорнути | menu | verified | yes | AppKit |
| Zoom | Оптимізувати | menu | verified | yes | Safari Window menu; page zoom is Масштаб |
| Bring All to Front | Усі наперед | menu | verified | yes | AppKit |
| Enter Full Screen | Увійти до повноекранного режиму | menu | verified | yes | AppKit |
| Exit Full Screen | Вийти з повноекранного режиму | menu | verified | yes | AppKit |
| Full Screen | Повноекранний режим / На весь екран | platform | verified | no | concept; window menu item "На весь екран" (mchl4fbe2921) |
| Zoom In | Наблизити | menu | verified | yes | Safari MainMenu |
| Zoom Out | Віддалити | menu | verified | yes | Safari MainMenu |
| Actual Size | Фактичний розмір | menu | verified | yes | Safari MainMenu |
| Reload Page | Перезавантажити сторінку | menu | verified | yes | Safari MainMenu |
| Reload | Перезавантажити | browser | verified | no | Safari |
| Stop Loading | Зупинити | menu | verified | no | Safari View menu |
| Print… | Друкувати… | menu | verified | yes | Safari MainMenu |
| Page Setup… | Параметри сторінки… | menu | standard | yes | macOS File menu |
| Save Page As… | Зберегти сторінку як… | menu | standard | yes | Chrome wording; Safari has "Зберегти як…" |
| Open File… | Відкрити файл… | menu | verified | yes | Safari MainMenu |
| Close Window | Закрити вікно | menu | verified | yes | Safari MainMenu |
| Close Tab | Закрити вкладку | menu | verified | yes | Safari MainMenu |
| New Window | Нове вікно | menu | verified | yes | Safari MainMenu |
| New Tab | Нова вкладка | menu | verified | yes | Safari MainMenu |
| New Private Window | Нове приватне вікно | menu | verified | yes | https://support.apple.com/uk-ua/guide/safari/ibrw1069/mac |
| New Incognito Window | Нове анонімне вікно | browser | verified | yes | https://support.google.com/chrome/answer/95464?hl=uk |
| Incognito | Анонімний режим | browser | verified | yes | Chrome; window: анонімне вікно |
| Private window | Приватне вікно | platform | verified | yes | Safari ibrw1069 |
| Private Browsing | Приватний перегляд | platform | verified | yes | Safari ibrw1069 |
| Reopen Closed Window | Відкрити останнє закрите вікно | browser | verified | yes | Safari MainMenu |
| Recently Closed | Недавно закриті | menu | verified | yes | Safari |
| Show All History | Показати всю історію | menu | verified | yes | Safari |
| Clear History… | Очистити історію… | menu | verified | yes | Safari |
| Show Next Tab | Показати наступну вкладку | menu | verified | yes | Safari and AppKit |
| Show Previous Tab | Показати попередню вкладку | menu | verified | yes | Safari and AppKit |
| Duplicate Tab | Дублювати вкладку | menu | verified | yes | Safari |
| Pin Tab | Закріпити вкладку | menu | verified | yes | https://support.apple.com/uk-ua/guide/safari/ibrw0495694f/mac |
| Unpin Tab | Відкріпити вкладку | menu | verified | yes | Safari ibrw0495694f |
| Mute Tab | Вимкнути звук на вкладці | browser | verified | yes | Safari |
| Unmute Tab | Увімкнути звук на вкладці | browser | verified | yes | Safari |
| Move Tab to New Window | Винести вкладку в нове вікно | menu | verified | yes | AppKit and sfri11576 |
| Merge All Windows | Обʼєднати всі вікна | menu | verified | yes | AppKit |
| Developer Tools | Інструменти розробника | browser | verified | yes | same as macOS privacy category, mchl211c911f |
| Inspect Element | Перевірити елемент | menu | verified | yes | Safari/WebKit |
| JavaScript Console | Консоль JavaScript | browser | verified | yes | Safari "Показати консоль JavaScript" |
| View Page Source | Показати вихідний код сторінки | browser | verified | yes | Safari |
| Keyboard Shortcuts | Клавіатурні скорочення | platform | verified | yes | System Settings, Keyboard |
| Check for Updates… | Перевірити наявність оновлень… | menu | standard | yes | |
| Share… | Поширити… | menu | verified | yes | Safari MainMenu |
| Tab | Вкладка | platform | verified | no | browser tab; the Tab key is "Tab" |
| Tabs | Вкладки | platform | verified | no | Safari Settings tab |
| Window | Вікно | platform | verified | no | |
| Tab group | Група вкладок | platform | verified | yes | Safari; plural Групи вкладок |
| Favorites | Улюблені | platform | verified | yes | Safari; bar: смуга улюблених |
| Favorite | Улюблене / улюблена вкладка | platform | decided | no | Apple has no singular; one item is "улюблена вкладка" |
| Bookmarks | Закладки | platform | verified | yes | Safari |
| Bookmark | Закладка | platform | verified | no | Safari |
| Add Bookmark | Додати закладку… | menu | verified | yes | Safari MainMenu, with ellipsis |
| History | Історія | platform | verified | no | Safari |
| Downloads | Викачування | platform | verified | yes | Safari "Показати викачування"; Finder folder is "Викачане"; not Завантаження |
| Download | Викачування / викачати | platform | verified | no | noun / verb (Safari) |
| Picture in Picture | Кадр у кадрі / режим «Кадр у кадрі» | platform | verified | yes | Safari |
| Split View | Split View | platform | verified | yes | Apple keeps English: "у режимі Split View", mchl4fbe2921 |
| Full Disk Access | Повний доступ до диска | platform | verified | yes | System Settings and mchl211c911f |
| Privacy & Security | Приватність і безпека | platform | verified | yes | System Settings |
| System Settings | Системні параметри | platform | verified | yes | AppKit |
| Settings | Параметри | platform | verified | no | Safari; not Налаштування |
| Settings… | Параметри… | menu | verified | yes | AppKit |
| General | Загальні | platform | verified | no | Safari Settings tab |
| Appearance | Вигляд | platform | verified | no | System Settings pane |
| Advanced | Експертні | platform | verified | no | Safari Settings tab |
| Extensions | Розширення | platform | verified | yes | Safari Settings tab |
| Extension | Розширення | platform | verified | no | Safari |
| Passwords | Паролі | platform | verified | yes | Safari Settings and app name |
| Apple Passwords | Паролі / програма «Паролі» | platform | verified | yes | https://support.apple.com/uk-ua/guide/passwords/welcome/mac |
| Keychain | Вʼязка | platform | verified | yes | iCloud Keychain: Вʼязка iCloud |
| Keychain Access | Ключар | platform | verified | yes | app name: https://support.apple.com/uk-ua/guide/keychain-access/welcome/mac |
| Profile | Профіль | platform | verified | no | Safari |
| Profiles | Профілі | platform | verified | yes | Safari Settings tab |
| Sidebar | Бічна панель | platform | verified | yes | Safari |
| Show Sidebar | Показати бічну панель | menu | verified | yes | Safari |
| Hide Sidebar | Сховати бічну панель | menu | verified | yes | AppKit |
| Toggle Sidebar | Показати або сховати бічну панель | browser | decided | no | Arx command; Apple pattern from Safari help |
| Reader | Зручне читання | platform | verified | yes | https://support.apple.com/uk-ua/guide/safari/sfri32632/mac |
| Reading Mode | Режим читання | browser | verified | yes | https://support.google.com/chrome/answer/14218344?hl=uk |
| Reading List | Читанка | platform | verified | yes | https://support.apple.com/uk-ua/guide/safari/sfri35905/mac |
| Website | Вебсайт | platform | verified | no | Safari |
| Websites | Вебсайти | platform | verified | no | Safari Settings tab |
| Site | Сайт / вебсайт | browser | verified | no | Chrome сайт; Safari вебсайт |
| Site Settings | Параметри вебсайту | browser | verified | yes | Safari; Chrome says "Налаштування сайтів", don't use |
| Permissions | Дозволи | browser | verified | no | Safari and Chrome |
| Allow | Дозволити | ui | verified | no | Safari |
| Don't Allow | Не дозволяти | ui | verified | yes | Safari |
| Always Allow | Дозволяти завжди | ui | verified | yes | Safari |
| Allow Once | Дозволити раз | ui | verified | yes | Safari |
| Ask | Запитувати | ui | verified | no | Safari permission option |
| Block | Блокувати | ui | verified | no | Safari; Safari's Deny option is "Заборонити" |
| Camera | Камера | platform | verified | no | System Settings |
| Microphone | Мікрофон | platform | verified | no | System Settings |
| Location | Місцезнаходження | platform | verified | no | Chrome site setting (114662); macOS: Служби локації |
| Notifications | Сповіщення | platform | verified | no | System Settings |
| Cookies | Файли cookie | browser | verified | no | Safari |
| Cache | Кеш | browser | verified | no | Safari |
| Clear Cache | Очистити кеш | browser | standard | yes | Safari "Очистити кеші" |
| Clear History | Очистити історію | browser | verified | yes | Safari |
| Browsing data | Дані вебперегляду | browser | verified | yes | https://support.google.com/chrome/answer/2392709?hl=uk |
| Autofill | Автозаповнення | platform | verified | yes | Safari Settings tab |
| Passkey | Ключ допуску | platform | verified | yes | Passwords guide; System Settings |
| Passkeys | Ключі допуску | platform | verified | yes | |
| Sign in | Увійти | ui | verified | no | |
| Sign-in | Вхід | ui | verified | no | |
| Sign Out | Вийти | ui | verified | no | |
| Account | Обліковий запис | ui | verified | no | System Settings |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | verified | yes | never translated |
| Mission Control | Mission Control | platform | verified | yes | never translated |
| Spaces (macOS) | Простори / Spaces | platform | verified | no | mh14112; singular простір; Apple also writes "простори Spaces". Never use for Arx spaces |
| Desktop | Робочий стіл | platform | verified | no | capitalized as Apple does |
| Dock | Dock | platform | verified | yes | |
| Finder | Finder | platform | verified | yes | never translated |
| Menu bar | Смуга меню | platform | verified | yes | System Settings |
| Language & Region | Мова і регіон | platform | verified | yes | System Settings |
| Translate | Перекласти | platform | verified | no | Safari "Перекласти вебсторінку" |
| Translation | Переклад | platform | verified | no | |
| Default browser | Основний браузер | platform | verified | yes | System Settings |
| Default web browser | Основний веббраузер / основний браузер | platform | verified | no | Safari help ibrwa008; System Settings label "Основний браузер" |
| Applications | Програми | platform | verified | no | the folder (Finder) and apps in general |
| Move to Applications | Перемістити в папку «Програми» | ui | standard | yes | |
| Login Items | Автозапуск | platform | verified | yes | System Settings; not "Елементи входу" |
| Battery Saver | Режим енергозбереження | browser | verified | yes | Chrome https://support.google.com/chrome/answer/12929150?hl=uk; macOS Low Power Mode is "Режим економії заряду" |
| Memory Saver | Заощадження памʼяті | browser | verified | yes | Chrome 12929150 |
| Address | Адреса | browser | verified | no | Safari |
| URL | URL / URL-адреса | browser | verified | no | Safari |
| Link | Посилання | browser | verified | no | |
| Links | Посилання | browser | standard | no | |
| Copy Link | Скопіювати посилання | menu | verified | yes | Safari |
| Open Link in New Tab | Відкрити посилання у новій вкладці | menu | verified | yes | Safari/WebKit |
| Open Link in New Window | Відкрити посилання в новому вікні | menu | verified | yes | Safari/WebKit |
| Download Linked File | Викачати файл | menu | verified | yes | Safari/WebKit |
| Copy Image | Скопіювати зображення | menu | verified | yes | Safari/WebKit |
| Save Image As… | Зберегти зображення як… | menu | verified | yes | Safari/WebKit |
| Look Up | Тлумачити | menu | verified | yes | with text: Тлумачити «%@» |
| Search with Google | Шукати у Google | menu | verified | yes | AppKit "Search with %@" |
| Back | Назад | browser | verified | no | |
| Forward | Вперед | browser | verified | no | |
| Home | Домашня сторінка | browser | verified | no | Safari |
| Search | Пошук / шукати | ui | verified | no | noun / verb |
| Search engine | Пошукова система | browser | verified | yes | Safari |
| Find on Page | Знайти на сторінці | browser | standard | yes | |
| Page | Сторінка | browser | standard | no | |
| Pages | Сторінки | browser | standard | no | |
| Web page | Вебсторінка | browser | verified | no | Safari; one word, no hyphen |
| Media | Медіа | browser | verified | no | macOS "Медіа і Apple Music" |
| Video | Відео | ui | verified | no | |
| Mute | Вимкнути звук | browser | verified | no | Safari |
| Unmute | Увімкнути звук | browser | verified | no | Safari |
| Play | Відтворити | ui | verified | no | |
| Pause | Пауза / призупинити | ui | verified | no | button label / verb |
| Cast | Транслювати… / трансляція | browser | verified | yes | Chrome: https://www.google.com/intl/uk/chrome/browser-features/ (verb); exact menu label not seen |
| Screenshot | Знімок екрана | platform | verified | yes | |
| Capture | Знімок / зробити знімок | ui | decided | no | page capture; consistent with Знімок екрана |
| Print | Друкувати | ui | verified | no | Safari; noun Друк |
| Share | Поширити | platform | verified | no | Safari |
| Open | Відкрити | ui | verified | no | |
| Close | Закрити | ui | verified | no | |
| Save | Зберегти | ui | verified | no | |
| Cancel | Скасувати | ui | verified | no | Apple button |
| Done | Готово | ui | verified | no | |
| OK | OK | ui | verified | no | Latin letters |
| Delete | Видалити | ui | verified | no | |
| Remove | Вилучити | ui | verified | no | Apple distinguishes it from Видалити |
| Rename | Перейменувати | ui | verified | no | |
| Rename… | Перейменувати… | ui | verified | no | |
| Add | Додати | ui | verified | no | |
| Edit… | Редагувати… | ui | verified | no | Safari "Редагувати" |
| Import | Імпортувати | ui | verified | no | |
| Export | Експортувати | ui | verified | no | |
| Install | Інсталювати | ui | verified | no | System Settings; not встановити |
| Uninstall | Деінсталювати | ui | verified | no | Safari |
| Update | Оновити | ui | verified | no | |
| Restore | Відновити | ui | verified | no | |
| Reset | Скинути | ui | verified | no | |
| Clear | Очистити | ui | verified | no | |
| Turn On | Увімкнути | ui | verified | no | |
| Turn Off | Вимкнути | ui | verified | no | |
| On | Увімкн. | ui | verified | no | switch state |
| Off | Вимкн. | ui | verified | no | switch state |
| Show | Показати | ui | verified | no | |
| Hide | Сховати | ui | verified | no | |
| Move | Перемістити | ui | verified | no | |
| Choose… | Вибрати… | ui | verified | no | |
| Continue | Продовжити | ui | verified | no | |
| Try Again | Спробувати ще раз | ui | standard | no | System Settings has "Ще раз" and "Спробуйте ще раз" |
| Not Now | Не зараз | ui | verified | no | |
| Learn More | Докладніше | ui | verified | no | |
| Default | Типово / стандартний | ui | verified | no | Safari "Типово"; adjective стандартний |
| None | Немає | ui | verified | no | |
| Always | Завжди | ui | verified | no | |
| Never | Ніколи | ui | verified | no | |
| Name | Назва / імʼя | ui | verified | no | things: Назва; people: Імʼя |
| Folder | Папка | platform | verified | no | |
| New Folder | Нова папка | menu | verified | yes | |
| Archive | Архів / архівувати | ui | standard | no | noun / verb |
| Archived | В архіві | ui | standard | no | |
| Theme | Тема | ui | verified | no | |
| Color | Колір | ui | verified | no | |
| Icon | Іконка | ui | verified | no | Apple: «Значок на іконці програми»; значок is a badge |
| Light | Світлий | platform | verified | no | agrees with "вигляд" |
| Dark | Темний | platform | verified | no | |
| Automatic | Автоматично | platform | verified | no | |
| System | Як у системі / система | ui | standard | no | appearance option: Як у системі |
| Shortcut | Клавіатурне скорочення / скорочення | ui | verified | no | System Settings; the Shortcuts app is "Швидкі команди" |
| Shortcuts | Клавіатурні скорочення | ui | verified | no | |
| Command | Команда | ui | standard | no | the key is "Command" |
| Assistant | Асистент | ui | standard | no | AI assistant |
| Agent | Агент | ui | standard | no | |
| Chat | Чат | ui | standard | no | |
| Chats | Чати | ui | standard | no | |
| Report a Problem… | Повідомити про проблему… | ui | unverified | yes | Safari's own item reads "Звітувати про недоліки…"; Apple form for this phrase not confirmed |
| Crash reports | Звіти про збої | ui | standard | yes | |
| Developer | Розробник | ui | verified | no | Safari |
| Element | Елемент | ui | standard | no | |
| Proxy | Проксі | browser | verified | no | Network settings "Проксі" |
| Arx | Arx | arx | decided | yes | brand, never translated or transliterated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | Розділ | arx | decided | no | Apple uses простір for macOS Spaces; розділ is a short native word for a sidebar page |
| Spaces | Розділи | arx | decided | no | plural of Розділ |
| Space root | Корінь розділу | arx | decided | no | rarely in UI |
| Pinned tab | Закріплена вкладка | arx | verified | yes | Safari |
| Favorite tab | Улюблена вкладка | arx | decided | yes | from Safari's Улюблені |
| Regular tab | Звичайна вкладка | arx | decided | yes | |
| Bookmark Tab | Додати вкладку в закладки | arx | decided | yes | Arx menu item; pins the tab |
| Tab Archive | Архів вкладок | arx | decided | yes | uses Вкладка |
| Clean Copy | Чисте копіювання | arx | decided | yes | copying a link without tracking parameters |
| Copy Clean Link | Скопіювати чисте посилання | arx | decided | yes | |
| Clean Link | Чисте посилання | arx | decided | yes | |
| Original Link | Оригінальне посилання | arx | decided | yes | |
| Proxy Link | Проксі-посилання | arx | decided | yes | loanword проксі, as macOS network settings |
| Copy Proxy Link | Скопіювати проксі-посилання | arx | decided | yes | |
| PiP | PiP | arx | decided | yes | keep; spelled out it is Кадр у кадрі |
| Page PiP | PiP сторінки | arx | decided | yes | page + PiP |
| Command Bar | Панель команд | arx | decided | yes | |
| Media | Медіа | arx | decided | no | SideMenu tab; matches the Media row |
| SideMenu | SideMenu | arx | decided | no | not in UI text; never "бічна панель", which is the Sidebar |
| Site menu | Меню сайту | arx | decided | yes | |
| urlbar | адреса | arx | decided | no | not in UI text; where shown, say "адреса" or "поле адреси" |
| Empty page | Порожня сторінка | arx | decided | yes | |
| Routing rule | Правило маршрутизації | arx | decided | yes | |
| Search shortcut | Пошукове скорочення | arx | decided | yes | keyword that sends a query to a site's search; скорочення as in Apple's keyboard shortcuts |
| bang | bang | arx | decided | yes | keep English |
| Badge | Значок | arx | verified | yes | Apple's word for icon badges (Notifications settings) |
| Organization | Упорядкування | arx | decided | no | Apple's Safari help heading "Упорядкування перегляду"; never "організація" (company) |
| Browser data | Дані браузера | arx | decided | yes | |
| Link Status | Стан посилання | arx | decided | yes | Settings section; Safari "панель стану" |
| Live Calendar | Живий календар | arx | decided | yes | |
| Setup Guide | Посібник із налаштування | arx | decided | yes | |
| Chrome Web Store | Вебмагазин Chrome | arx | verified | yes | https://support.google.com/chrome_webstore/answer/2664769?hl=uk (header also writes Веб-магазин Chrome) |
| WebKit | WebKit | arx | decided | yes | never translated |
| Chromium | Chromium | arx | decided | yes | never translated |
| MCP | MCP | arx | decided | yes | never translated |
| Arx Manual | Посібник користувача Arx | arx | decided | yes | Apple: "Посібник користувача Mac" |
| Arx Assistant | Асистент Arx | arx | decided | yes | |
| OS workspace | Простір Spaces | platform | verified | yes | a macOS Space, distinct from an Arx space (Розділ) |
| Sync | Синхронізація | ui | standard | no | iCloud sync: синхронізація iCloud |
