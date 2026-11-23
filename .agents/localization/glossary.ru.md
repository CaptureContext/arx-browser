# Glossary: Russian (ru)

Translators of Arx into Russian use these terms. A term here wins over any other choice.

## Language rules

- Address: formal "Вы", capitalized in the middle of a sentence too ("Если Вы работаете с приложениями в полноэкранном режиме…"), as Apple's Russian macOS does. Verified: https://support.apple.com/ru-ru/guide/mac-help/mh14112/mac and https://support.apple.com/ru-ru/guide/mac-help/mchl4fbe2921/mac
- Sources: "verified" rows were checked this session either on Apple's or Google's Russian help pages (URL in Note) or in the Russian string tables that ship with macOS 27.3 on the build Mac: Safari (Safari.app MainMenu and the Safari/WebKit frameworks), AppKit menus, System Settings panes. Note says "Safari", "AppKit" or "System Settings" for those.
- Capitalization: sentence case everywhere: only the first word and proper names are capitalized ("Новое частное окно", "Закрепить вкладку"). Apple capitalizes "Рабочий стол" when it names the macOS desktop.
- Buttons and menu commands: perfective infinitive ("Скопировать", "Удалить", "Перезагрузить страницу"), never imperative. Settings checkboxes: imperfective infinitive ("Проверять правописание при вводе").
- Punctuation and ellipsis: one character "…" (U+2026), exactly where English has it. Quotation marks: «ёлочки», nested „лапки“. Names of apps and settings in running text go in «» ("приложение «Пароли»", "Safari > «Настройки»"). Use an em dash with spaces " — ".
- Letter ё: Apple writes "е" ("закрепленная", "отчеты"); do the same.
- Apps: "приложение" (not "программа"), but the Applications folder is "Программы".
- OK button: "ОК" in Cyrillic letters, as Apple's Russian strings write it.
- Plural categories: one, few, many, other (e.g. 1 вкладка, 2 вкладки, 5 вкладок, 1,5 вкладки).
- macOS Spaces: Apple calls them "пространства Spaces" or "рабочие пространства Spaces" ("дополнительные рабочие столы, которые называются пространствами"); the Keyboard settings also say "На одну область влево" for "Move left a Space". Mission Control stays in English. Verified: https://support.apple.com/ru-ru/guide/mac-help/mh14112/mac and System Settings strings.
- Arx space: "раздел" (plural "разделы"), because "пространство" and "область" are both Apple's words for macOS Spaces in Russian, and "раздел" is a short native word for one page of the sidebar. Do not use "раздел" for parts of Settings: call those by their name or "группа настроек".
- Sidebar is "боковое меню" (Apple). Never use "боковое меню" for SideMenu or anything else.
- Settings are "Настройки" (Safari > «Настройки…»), System Settings are "Системные настройки".
- Length: Russian runs 15–30% longer than English; prefer Apple's shorter forms ("Убрать в Dock", "Выкл. звук на вкладке") where space is tight.
- Keep in Latin script and never decline: Arx, Little Arx, Peek, Air Traffic Control, Runway, bang, PiP, WebKit, Chromium, MCP, iCloud, Touch ID, Finder, Dock, Mission Control, Split View, Safari, Google, Chrome. Inflect the noun in front instead ("в окне Little Arx", "в приложении Finder").

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | Файл | menu | verified | no | Safari MainMenu |
| Edit | Правка | menu | verified | no | Safari MainMenu; as a verb button: Изменить |
| View | Вид | menu | verified | no | Safari MainMenu |
| History | История | menu | verified | no | Safari MainMenu |
| Window | Окно | menu | verified | no | Safari MainMenu |
| Help | Справка | menu | verified | no | Safari MainMenu |
| Services | Службы | menu | verified | yes | Safari MainMenu |
| About Arx | О приложении Arx | menu | verified | yes | Safari writes "О приложении Safari" |
| Hide Arx | Скрыть Arx | menu | verified | yes | Safari writes "Скрыть Safari" |
| Hide Others | Скрыть остальные | menu | verified | yes | Safari MainMenu |
| Show All | Показать все | menu | verified | no | Safari MainMenu |
| Quit Arx | Завершить Arx | menu | verified | yes | Safari writes "Завершить Safari" |
| Undo | Отменить | menu | verified | no | Safari MainMenu; same word as Cancel |
| Redo | Повторить | menu | verified | no | Safari MainMenu |
| Cut | Вырезать | menu | verified | no | AppKit |
| Copy | Скопировать | menu | verified | no | AppKit |
| Paste | Вставить | menu | verified | no | AppKit |
| Paste and Match Style | Вставить и согласовать стиль | menu | verified | yes | AppKit |
| Select All | Выбрать все | menu | verified | yes | AppKit |
| Find | Поиск / Найти… | menu | verified | no | Edit submenu is "Поиск", its item "Найти…" (Safari) |
| Use Selection for Find | Найти выбранное | menu | verified | yes | Safari MainMenu |
| Jump to Selection | Перейти к выбранному | menu | verified | yes | Safari MainMenu |
| Spelling and Grammar | Правописание и грамматика | menu | verified | yes | Safari MainMenu |
| Show Spelling and Grammar | Показать правописание и грамматику | menu | verified | yes | AppKit |
| Check Document Now | Проверить документ сейчас | menu | verified | no | AppKit; Safari shortens to "Проверить документ" |
| Check Grammar With Spelling | Проверять грамматику и правописание | menu | verified | yes | AppKit |
| Correct Spelling Automatically | Автоматически исправлять ошибки | menu | verified | yes | AppKit |
| Substitutions | Замены | menu | verified | yes | Safari MainMenu |
| Smart Links | Смарт-ссылки | menu | verified | yes | AppKit |
| Transformations | Преобразования | menu | verified | yes | Safari MainMenu |
| Make Upper Case | Прописные | menu | verified | yes | AppKit |
| Make Lower Case | Строчные | menu | verified | yes | AppKit |
| Capitalize | С заглавной буквы | menu | verified | yes | AppKit |
| Minimize | Убрать в Dock | menu | verified | yes | AppKit; not "Свернуть" |
| Zoom | Изменить масштаб | menu | verified | no | AppKit Window menu; same words as page zoom |
| Bring All to Front | Все окна — на передний план | menu | verified | yes | AppKit |
| Enter Full Screen | Перейти в полноэкранный режим | menu | verified | yes | AppKit |
| Exit Full Screen | Выйти из полноэкранного режима | menu | verified | yes | AppKit |
| Full Screen | Полноэкранный режим / На весь экран | platform | verified | no | concept; window menu item is "На весь экран" (mchl4fbe2921) |
| Zoom In | Увеличить | menu | verified | no | Safari MainMenu |
| Zoom Out | Уменьшить | menu | verified | no | Safari MainMenu |
| Actual Size | Реальный размер | menu | verified | yes | Safari MainMenu |
| Reload Page | Перезагрузить страницу | menu | verified | yes | Safari MainMenu |
| Reload | Перезагрузить | browser | verified | no | Safari |
| Stop Loading | Остановить | menu | verified | no | Safari View menu "Остановить" |
| Print… | Напечатать… | menu | verified | yes | Safari MainMenu |
| Page Setup… | Параметры страницы… | menu | standard | yes | macOS File menu |
| Save Page As… | Сохранить страницу как… | menu | standard | yes | Chrome wording; Safari has "Сохранить как…" |
| Open File… | Открыть файл… | menu | verified | yes | Safari MainMenu |
| Close Window | Закрыть окно | menu | verified | yes | Safari MainMenu |
| Close Tab | Закрыть вкладку | menu | verified | yes | Safari MainMenu |
| New Window | Новое окно | menu | verified | yes | Safari MainMenu |
| New Tab | Новая вкладка | menu | verified | yes | Safari MainMenu |
| New Private Window | Новое частное окно | menu | verified | yes | https://support.apple.com/ru-ru/guide/safari/ibrw1069/mac |
| New Incognito Window | Новое окно в режиме инкогнито | browser | verified | yes | https://support.google.com/chrome/answer/95464?hl=ru |
| Incognito | Режим инкогнито / инкогнито | browser | verified | yes | Chrome; window: окно в режиме инкогнито |
| Private window | Частное окно | platform | verified | yes | Safari ibrw1069 |
| Private Browsing | Частный доступ / режим частного доступа | platform | verified | yes | Safari strings and ibrw1069 |
| Reopen Closed Window | Открыть последнее закрытое окно | browser | verified | yes | Safari MainMenu |
| Recently Closed | Недавно закрытые | menu | verified | yes | Safari |
| Show All History | Показать всю историю | menu | verified | yes | Safari |
| Clear History… | Очистить историю… | menu | verified | yes | Safari |
| Show Next Tab | Показать следующую вкладку / На следующую вкладку | menu | verified | yes | AppKit / Safari Window menu |
| Show Previous Tab | Показать предыдущую вкладку / На предыдущую вкладку | menu | verified | yes | AppKit / Safari Window menu |
| Duplicate Tab | Дублировать вкладку | menu | verified | yes | Safari |
| Pin Tab | Закрепить вкладку | menu | verified | yes | https://support.apple.com/ru-ru/guide/safari/ibrw0495694f/mac |
| Unpin Tab | Открепить вкладку | menu | verified | yes | Safari ibrw0495694f |
| Mute Tab | Выключить звук на вкладке | browser | verified | yes | Safari; short form "Выкл. звук на вкладке" |
| Unmute Tab | Включить звук на вкладке | browser | verified | yes | Safari; short form "Вкл. звук на вкладке" |
| Move Tab to New Window | Переместить вкладку в новое окно | menu | verified | yes | AppKit and sfri11576 |
| Merge All Windows | Объединить все окна | menu | verified | yes | AppKit |
| Developer Tools | Инструменты разработчика | browser | verified | yes | same as macOS privacy category, mchl211c911f |
| Inspect Element | Проверить элемент | menu | verified | yes | Safari/WebKit |
| JavaScript Console | Консоль JavaScript | browser | verified | yes | Safari "Показать консоль JavaScript" |
| View Page Source | Показать программный код страницы | browser | verified | yes | Safari; not Chrome's wording |
| Keyboard Shortcuts | Сочетания клавиш | platform | verified | yes | System Settings, Keyboard |
| Check for Updates… | Проверить наличие обновлений… | menu | standard | yes | |
| Share… | Поделиться… | menu | verified | yes | Safari MainMenu |
| Tab | Вкладка | platform | verified | no | browser tab; the Tab key is "Tab" |
| Tabs | Вкладки | platform | verified | no | Safari Settings tab |
| Window | Окно | platform | verified | no | |
| Tab group | Группа вкладок | platform | verified | yes | Safari; plural Группы вкладок |
| Favorites | Избранное | platform | verified | yes | Safari; bar: строка «Избранное» |
| Favorite | Избранное / избранная вкладка | platform | decided | no | Apple has no singular; one item is "избранная вкладка" |
| Bookmarks | Закладки | platform | verified | yes | Safari |
| Bookmark | Закладка | platform | verified | no | Safari |
| Add Bookmark | Добавить в закладки… | menu | verified | yes | Safari MainMenu, with ellipsis |
| History | История | platform | verified | no | Safari |
| Downloads | Загрузки | platform | verified | yes | Safari "Показать загрузки"; Finder folder "Загрузки" |
| Download | Загрузка / загрузить | platform | verified | no | noun / verb (Safari) |
| Picture in Picture | Картинка в картинке / режим «Картинка в картинке» | platform | verified | yes | Safari: "Войти в режим «Картинка в картинке»" |
| Split View | Split View | platform | verified | yes | Apple keeps English: "режим Split View", mchl4fbe2921 |
| Full Disk Access | Доступ к диску / полный доступ к диску | platform | verified | no | System Settings pane label is "Доступ к диску"; help text says "Полный доступ к диску" (mchl211c911f). Use the label in navigation paths |
| Privacy & Security | Конфиденциальность и безопасность | platform | verified | yes | System Settings |
| System Settings | Системные настройки | platform | verified | yes | AppKit |
| Settings | Настройки | platform | verified | no | Safari |
| Settings… | Настройки… | menu | verified | yes | AppKit |
| General | Основные | platform | verified | no | Safari Settings tab |
| Appearance | Оформление | platform | verified | no | System Settings pane |
| Advanced | Дополнения | platform | verified | no | Safari Settings tab |
| Extensions | Расширения | platform | verified | yes | Safari Settings tab |
| Extension | Расширение | platform | verified | no | Safari |
| Passwords | Пароли | platform | verified | yes | Safari Settings and app name |
| Apple Passwords | Пароли / приложение «Пароли» | platform | verified | yes | https://support.apple.com/ru-ru/guide/passwords/welcome/mac |
| Keychain | Связка ключей | platform | verified | yes | iCloud Keychain: Связка ключей iCloud |
| Keychain Access | Связка ключей / приложение «Связка ключей» | platform | verified | yes | app has the same name as the keychain: https://support.apple.com/ru-ru/guide/keychain-access/welcome/mac |
| Profile | Профиль | platform | verified | no | Safari |
| Profiles | Профили | platform | verified | yes | Safari Settings tab |
| Sidebar | Боковое меню | platform | verified | yes | Safari; not "боковая панель" |
| Show Sidebar | Показать боковое меню | menu | verified | yes | Safari |
| Hide Sidebar | Скрыть боковое меню | menu | verified | yes | AppKit |
| Toggle Sidebar | Показать или скрыть боковое меню | browser | decided | no | Arx command; Apple pattern from Safari help |
| Reader | Для чтения / режим «Для чтения» | platform | verified | yes | https://support.apple.com/ru-ru/guide/safari/sfri32632/mac |
| Reading Mode | Режим чтения | browser | verified | yes | https://support.google.com/chrome/answer/14218344?hl=ru |
| Reading List | Список для чтения | platform | verified | yes | https://support.apple.com/ru-ru/guide/safari/sfri35905/mac |
| Website | Сайт | platform | verified | no | Safari |
| Websites | Сайты | platform | verified | no | Safari Settings tab |
| Site | Сайт | browser | verified | no | |
| Site Settings | Настройки сайта | browser | verified | yes | Safari and Chrome agree |
| Permissions | Разрешения / права доступа | browser | verified | no | Chrome "разрешения"; Safari heading "Права доступа" |
| Allow | Разрешить | ui | verified | no | Safari |
| Don't Allow | Не разрешать | ui | verified | yes | Safari |
| Always Allow | Разрешать всегда | ui | verified | yes | Safari |
| Allow Once | Разрешить один раз | ui | verified | yes | Safari |
| Ask | Спросить | ui | verified | no | Safari permission option |
| Block | Блокировать | ui | verified | no | Safari; Safari's Deny option is "Отказать" |
| Camera | Камера | platform | verified | no | System Settings |
| Microphone | Микрофон | platform | verified | no | System Settings |
| Location | Геопозиция | platform | verified | no | Safari permission; macOS: Службы геолокации |
| Notifications | Уведомления | platform | verified | no | System Settings |
| Cookies | Файлы cookie | browser | verified | no | Safari |
| Cache | Кэш | browser | verified | no | Safari (Chrome writes "кеш"; follow Apple) |
| Clear Cache | Очистить кэш | browser | standard | yes | Safari "Очистить кэши" |
| Clear History | Очистить историю | browser | verified | yes | Safari |
| Browsing data | Данные о работе в браузере | browser | verified | yes | https://support.google.com/chrome/answer/2392709?hl=ru |
| Autofill | Автозаполнение | platform | verified | yes | Safari Settings tab |
| Passkey | Ключ входа | platform | verified | yes | Passwords guide; System Settings "ключи входа" |
| Passkeys | Ключи входа | platform | verified | yes | |
| Sign in | Войти | ui | verified | no | |
| Sign-in | Вход | ui | verified | no | |
| Sign Out | Выйти | ui | verified | no | |
| Account | Учетная запись | ui | verified | no | System Settings; Apple Account is "Аккаунт Apple" |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | verified | yes | never translated |
| Mission Control | Mission Control | platform | verified | yes | never translated |
| Spaces (macOS) | Пространства Spaces / рабочие пространства Spaces | platform | verified | no | mh14112; singular пространство. Never use for Arx spaces |
| Desktop | Рабочий стол | platform | verified | no | capitalized as Apple does |
| Dock | Dock | platform | verified | yes | Apple also writes "панель Dock" |
| Finder | Finder | platform | verified | yes | never translated |
| Menu bar | Строка меню | platform | verified | yes | System Settings |
| Language & Region | Язык и регион | platform | verified | yes | System Settings |
| Translate | Перевести | platform | verified | no | Safari "Перевести веб-страницу" |
| Translation | Перевод | platform | verified | no | |
| Default browser | Браузер по умолчанию | platform | verified | yes | Safari help ibrwa008 |
| Default web browser | Веб-браузер по умолчанию | platform | verified | yes | System Settings, Desktop & Dock |
| Applications | Программы | platform | verified | no | the folder (Finder); apps in general are "приложения" |
| Move to Applications | Переместить в папку «Программы» | ui | standard | yes | |
| Login Items | Объекты входа | platform | verified | yes | System Settings |
| Battery Saver | Режим энергосбережения | browser | verified | yes | Chrome https://support.google.com/chrome/answer/12929150?hl=ru; also macOS Low Power Mode |
| Memory Saver | Экономия памяти | browser | verified | yes | Chrome 12929150 |
| Address | Адрес | browser | verified | no | Safari |
| URL | URL / URL-адрес | browser | verified | no | Safari |
| Link | Ссылка | browser | verified | no | |
| Links | Ссылки | browser | standard | no | |
| Copy Link | Скопировать ссылку | menu | verified | yes | Safari |
| Open Link in New Tab | Открыть ссылку в новой вкладке | menu | verified | yes | Safari/WebKit |
| Open Link in New Window | Открыть ссылку в новом окне | menu | verified | yes | Safari/WebKit |
| Download Linked File | Загрузить файл по ссылке | menu | verified | yes | Safari/WebKit |
| Copy Image | Скопировать изображение | menu | verified | yes | Safari/WebKit |
| Save Image As… | Сохранить изображение как… | menu | verified | yes | Safari/WebKit |
| Look Up | Найти | menu | verified | no | with text: Найти «%@» |
| Search with Google | Поиск в Google | menu | verified | yes | AppKit "Search with %@" |
| Back | Назад | browser | verified | no | |
| Forward | Вперед | browser | verified | no | |
| Home | Домашняя страница | browser | verified | no | Safari |
| Search | Поиск / искать | ui | verified | no | noun / verb |
| Search engine | Поисковая система | browser | verified | yes | Safari |
| Find on Page | Найти на странице | browser | standard | yes | |
| Page | Страница | browser | standard | no | |
| Pages | Страницы | browser | standard | no | |
| Web page | Веб-страница | browser | verified | no | Safari |
| Media | Медиа | browser | verified | no | macOS "Медиа и Apple Music" |
| Video | Видео | ui | verified | no | |
| Mute | Выключить звук | browser | verified | no | Safari |
| Unmute | Включить звук | browser | verified | no | Safari |
| Play | Воспроизвести | ui | verified | no | |
| Pause | Пауза / приостановить | ui | verified | no | button label / verb |
| Cast | Трансляция… / транслировать | browser | verified | yes | Chrome https://support.google.com/chromecast/answer/3228332?hl=ru |
| Screenshot | Снимок экрана | platform | verified | yes | |
| Capture | Снимок / сделать снимок | ui | decided | no | page capture; consistent with Снимок экрана |
| Print | Напечатать | ui | verified | no | Safari |
| Share | Поделиться | platform | verified | no | Safari |
| Open | Открыть | ui | verified | no | |
| Close | Закрыть | ui | verified | no | |
| Save | Сохранить | ui | verified | no | |
| Cancel | Отменить | ui | verified | no | Apple button |
| Done | Готово | ui | verified | no | |
| OK | ОК | ui | verified | no | Cyrillic О and К |
| Delete | Удалить | ui | verified | no | |
| Remove | Удалить / убрать | ui | verified | no | Apple uses Удалить; "убрать" when nothing is deleted |
| Rename | Переименовать | ui | verified | no | |
| Rename… | Переименовать… | ui | verified | no | |
| Add | Добавить | ui | verified | no | |
| Edit… | Изменить… | ui | verified | no | Safari "Изменить" |
| Import | Импортировать | ui | verified | no | |
| Export | Экспортировать | ui | verified | no | |
| Install | Установить | ui | verified | no | |
| Uninstall | Удалить | ui | verified | no | Safari |
| Update | Обновить | ui | verified | no | |
| Restore | Восстановить | ui | verified | no | |
| Reset | Сбросить | ui | verified | no | |
| Clear | Очистить | ui | verified | no | |
| Turn On | Включить | ui | verified | no | |
| Turn Off | Выключить | ui | verified | no | |
| On | Вкл. | ui | verified | no | switch state |
| Off | Выкл. | ui | verified | no | switch state |
| Show | Показать | ui | verified | no | |
| Hide | Скрыть | ui | verified | no | |
| Move | Переместить | ui | verified | no | |
| Choose… | Выбрать… | ui | verified | no | |
| Continue | Продолжить | ui | verified | no | |
| Try Again | Повторить / повторить попытку | ui | verified | no | System Settings |
| Not Now | Не сейчас | ui | verified | no | |
| Learn More | Подробнее | ui | verified | no | |
| Default | По умолчанию | ui | verified | no | |
| None | Нет | ui | verified | no | |
| Always | Всегда | ui | verified | no | |
| Never | Никогда | ui | verified | no | |
| Name | Название / имя | ui | verified | no | things: Название; people: Имя |
| Folder | Папка | platform | verified | no | |
| New Folder | Новая папка | menu | verified | yes | |
| Archive | Архив / архивировать | ui | standard | no | noun / verb |
| Archived | В архиве | ui | standard | no | |
| Theme | Тема | ui | verified | no | |
| Color | Цвет | ui | verified | no | |
| Icon | Значок | ui | verified | no | |
| Light | Светлое | platform | verified | no | agrees with "оформление"; adjust gender to the noun |
| Dark | Темное | platform | verified | no | as Light |
| Automatic | Автоматически | platform | verified | no | |
| System | Как в системе / система | ui | standard | no | appearance option: Как в системе |
| Shortcut | Сочетание клавиш | ui | verified | no | keyboard shortcut; not "Быстрые команды" (that is the Shortcuts app) |
| Shortcuts | Сочетания клавиш | ui | verified | no | |
| Command | Команда | ui | standard | no | the key is "Command" |
| Assistant | Ассистент | ui | standard | no | AI assistant |
| Agent | Агент | ui | standard | no | |
| Chat | Чат | ui | standard | no | |
| Chats | Чаты | ui | standard | no | |
| Report a Problem… | Сообщить о проблеме… | ui | standard | yes | Safari menu has "Сообщить о проблемах…" |
| Crash reports | Отчеты о сбоях | ui | standard | yes | |
| Developer | Разработчик | ui | verified | no | Safari |
| Element | Элемент | ui | standard | no | |
| Proxy | Прокси | browser | verified | no | Network settings "Прокси" |
| Arx | Arx | arx | decided | yes | brand, never translated or transliterated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | Раздел | arx | decided | no | Apple uses пространство and область for macOS Spaces; раздел is a short native word for a sidebar page |
| Spaces | Разделы | arx | decided | no | plural of Раздел |
| Space root | Корень раздела | arx | decided | no | rarely in UI |
| Pinned tab | Закрепленная вкладка | arx | verified | yes | Safari "закрепленная вкладка" |
| Favorite tab | Избранная вкладка | arx | decided | yes | from Safari's Избранное |
| Regular tab | Обычная вкладка | arx | decided | yes | |
| Bookmark Tab | Добавить вкладку в закладки | arx | decided | yes | Arx menu item; pins the tab |
| Tab Archive | Архив вкладок | arx | decided | yes | uses Вкладка |
| Clean Copy | Чистое копирование | arx | decided | yes | copying a link without tracking parameters |
| Copy Clean Link | Скопировать чистую ссылку | arx | decided | yes | |
| Clean Link | Чистая ссылка | arx | decided | yes | |
| Original Link | Исходная ссылка | arx | decided | yes | |
| Proxy Link | Прокси-ссылка | arx | decided | yes | loanword прокси, as macOS network settings |
| Copy Proxy Link | Скопировать прокси-ссылку | arx | decided | yes | |
| PiP | PiP | arx | decided | yes | keep; spelled out it is Картинка в картинке |
| Page PiP | PiP страницы | arx | decided | yes | page + PiP |
| Command Bar | Панель команд | arx | decided | yes | not "командная строка" (that is the terminal) |
| Media | Медиа | arx | decided | no | SideMenu tab; matches the Media row |
| SideMenu | SideMenu | arx | decided | no | not in UI text; never "боковое меню", which is the Sidebar |
| Site menu | Меню сайта | arx | decided | yes | |
| urlbar | адрес | arx | decided | no | not in UI text; where shown, say "адрес" or "поле адреса" |
| Empty page | Пустая страница | arx | decided | yes | |
| Routing rule | Правило маршрутизации | arx | decided | yes | |
| Search shortcut | Поисковое сокращение | arx | decided | yes | keyword that sends a query to a site's search |
| bang | bang | arx | decided | yes | keep English; plural bang-команды if needed |
| Badge | Наклейка | arx | verified | yes | Apple's word for icon badges (Notifications: «Наклейка на значке») |
| Organization | Упорядочивание | arx | decided | no | Apple's Safari help heading "Упорядочивание просмотра"; never "организация" (company) |
| Browser data | Данные браузера | arx | decided | yes | |
| Link Status | Состояние ссылки | arx | decided | yes | Settings section; Safari "строка состояния" |
| Live Calendar | Живой календарь | arx | decided | yes | |
| Setup Guide | Руководство по настройке | arx | decided | yes | |
| Chrome Web Store | Интернет-магазин Chrome | arx | verified | yes | https://support.google.com/chrome_webstore/answer/2664769?hl=ru |
| WebKit | WebKit | arx | decided | yes | never translated |
| Chromium | Chromium | arx | decided | yes | never translated |
| MCP | MCP | arx | decided | yes | never translated |
| Arx Manual | Руководство пользователя Arx | arx | decided | yes | Apple: "Руководство пользователя Mac" |
| Arx Assistant | Ассистент Arx | arx | decided | yes | |
| OS workspace | Пространство Spaces | platform | verified | yes | a macOS Space, distinct from an Arx space (Раздел) |
| Sync | Синхронизация | ui | standard | no | iCloud sync: синхронизация iCloud |
