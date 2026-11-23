# Glossary: Spanish (es)

Translators of Arx into Spanish use these terms. A term here wins over any other choice.

## Language rules

- Variant: Spain Spanish, Apple's "es" locale, not Latin American ("es-419"). Use Spain's vocabulary: "ordenador" if a computer must be named (prefer "Mac"), "vídeo", "móvil", "por omisión" for default, "Aceptar" for OK and Done.
- Address: informal "tú", as Apple's Spanish macOS and Safari do ("Puedes anclar cualquier sitio web que visites frecuentemente."). Imperatives use the tú form ("Abre", "Selecciona"). Verified: https://support.apple.com/es-es/guide/safari/ibrw0495694f/mac
- Sources: rows marked verified were checked on Apple's Spain Spanish support pages, on Google's Spanish Chrome help (hl=es), or against the Spanish strings that ship in Safari, AppKit and System Settings on macOS (the exact UI text Apple uses). Where a help page and the shipped UI differ, the shipped UI wins.
- Capitalization: sentence case everywhere, menus and buttons included: only the first word and proper names take a capital ("Nueva ventana privada", "Mostrar pestaña siguiente"). Product names keep their capitals (Safari, Mission Control, Split View, Arx).
- Articles in commands: Apple's Spanish menus usually drop the article ("Cerrar pestaña", "Duplicar pestaña", "Copiar enlace", "Mostrar barra lateral"). Follow that in menu items and buttons; use articles in sentences.
- Punctuation and ellipsis: Apple's single ellipsis character … (U+2026), never three dots, no space before it ("Ajustes…"). Quote UI names with curly double quotes “ ”, as Apple does ("Consultar “%@”"). Questions and exclamations open with ¿ and ¡.
- Buttons and menu items: infinitive verbs ("Añadir", "Cerrar pestaña"), never the imperative.
- Apple Spain vocabulary that differs from a literal or Latin American translation: OK and Done are "Aceptar"; Default is "Por omisión"; Choose… is "Seleccionar…"; Move is "Trasladar"; Settings is "Ajustes" (System Settings = "Ajustes del Sistema"); Add is "Añadir" (not "Agregar"); item is "ítem"; search engine is "buscador"; link is "enlace" (not "vínculo"); tab is "pestaña"; Pin Tab is "Anclar pestaña" (not "Fijar").
- Plural categories: one, many, other. "one" is exactly 1; "many" is for very large round numbers ("1 000 000 de pestañas").
- Numbers: a space (or point in older texts; follow the formatter) groups thousands, the decimal separator is a comma.
- macOS Spaces: Apple's settings keep "Spaces" in English ("Pantallas con Spaces separados"); help prose says "un Space" and also "espacio" or "escritorio" ("Cuando se trabaja en un Space, solo se muestran las ventanas que están en dicho Space."). Verified: https://support.apple.com/es-es/guide/mac-help/mh14112/mac
- Arx space: "sección" (feminine: "una sección", "Nueva sección", "Secciones"), because a space is a page of the sidebar and the word cannot be confused with Apple's "Space"/"espacio"/"escritorio", nor with "área", which Arx needs for capture areas ("Capturar área…"), nor with "entorno", which Arx needs for environment variables. Where English says "section" for something else (e.g. "the Developer section of Settings"), translate it as "apartado".
- Length: Spanish runs about 20 to 30 percent longer than English; keep button labels short and prefer Apple's short forms.

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | Archivo | menu | verified | no | Safari menu bar; never use Archivo for Archive |
| Edit | Edición | menu | verified | no | menu bar title; verb is Editar |
| View | Visualización | menu | verified | no | menu bar title; the verb "view" is Ver or Mostrar |
| History | Historial | menu | verified | no | Safari menu bar |
| Window | Ventana | menu | verified | no | menu bar title |
| Help | Ayuda | menu | verified | no | app Help menu is Ayuda de Arx |
| Services | Servicios | menu | verified | yes | app menu |
| About Arx | Acerca de Arx | menu | verified | yes | pattern of Acerca de Safari |
| Hide Arx | Ocultar Arx | menu | verified | yes | pattern of Ocultar Safari |
| Hide Others | Ocultar otras apps | menu | verified | yes | app menu |
| Show All | Mostrar todo | menu | verified | yes | app menu |
| Quit Arx | Salir de Arx | menu | verified | yes | pattern of Salir de Safari |
| Undo | Deshacer | menu | verified | yes | Edit menu |
| Redo | Rehacer | menu | verified | yes | Edit menu |
| Cut | Cortar | menu | verified | no | Edit menu |
| Copy | Copiar | menu | verified | no | Edit menu |
| Paste | Pegar | menu | verified | no | Edit menu |
| Paste and Match Style | Pegar con el mismo estilo | menu | verified | yes | Edit menu |
| Select All | Seleccionar todo | menu | verified | yes | Edit menu |
| Find | Buscar | menu | verified | no | Edit menu submenu; Find… is Buscar… |
| Use Selection for Find | Usar selección para buscar | menu | verified | yes | Edit › Buscar |
| Jump to Selection | Ir a la selección | menu | verified | yes | Edit › Buscar |
| Spelling and Grammar | Ortografía y gramática | menu | verified | yes | Edit submenu |
| Show Spelling and Grammar | Mostrar ortografía y gramática | menu | verified | yes | AppKit menu |
| Check Document Now | Comprobar documento ahora | menu | verified | yes | AppKit menu |
| Check Grammar With Spelling | Comprobar gramática con la ortografía | menu | verified | yes | AppKit menu |
| Correct Spelling Automatically | Corregir ortografía automáticamente | menu | verified | yes | AppKit menu |
| Substitutions | Sustituciones | menu | verified | yes | Edit submenu |
| Smart Links | Enlaces inteligentes | menu | verified | yes | Edit › Sustituciones |
| Transformations | Transformaciones | menu | verified | yes | Edit submenu |
| Make Upper Case | Todo en mayúsculas | menu | verified | yes | Edit › Transformaciones |
| Make Lower Case | Todo en minúsculas | menu | verified | yes | Edit › Transformaciones |
| Capitalize | Mayúsculas iniciales | menu | verified | yes | Edit › Transformaciones |
| Minimize | Minimizar | menu | verified | yes | Window menu |
| Zoom | Zoom | menu | verified | no | Window menu (window zoom); page zoom is Ampliar/Reducir |
| Bring All to Front | Traer todo al frente | menu | verified | yes | Window menu |
| Enter Full Screen | Usar pantalla completa | menu | verified | yes | AppKit menu |
| Exit Full Screen | Salir de pantalla completa | menu | verified | yes | AppKit menu |
| Full Screen | pantalla completa | platform | verified | yes | "a pantalla completa" |
| Zoom In | Ampliar | menu | verified | yes | Safari View menu |
| Zoom Out | Reducir | menu | verified | yes | Safari View menu |
| Actual Size | Tamaño real | menu | verified | yes | Safari View menu |
| Reload Page | Volver a cargar página | menu | verified | yes | Safari View menu |
| Reload | Volver a cargar | browser | verified | yes | Safari; not Recargar |
| Stop Loading | Detener carga | menu | standard | yes | Safari's item is just Detener |
| Print… | Imprimir… | menu | verified | yes | File menu |
| Page Setup… | Ajustar página… | menu | standard | yes | File menu |
| Save Page As… | Guardar página como… | menu | standard | yes | Chrome; Safari's item is Guardar como… |
| Open File… | Abrir archivo… | menu | verified | yes | Safari File menu |
| Close Window | Cerrar ventana | menu | verified | yes | AppKit menu |
| Close Tab | Cerrar pestaña | menu | verified | yes | Safari File menu |
| New Window | Nueva ventana | menu | verified | yes | Safari File menu |
| New Tab | Nueva pestaña | menu | verified | yes | Safari File menu |
| New Private Window | Nueva ventana privada | menu | verified | yes | Safari File menu |
| New Incognito Window | Nueva ventana de incógnito | browser | verified | yes | Chrome; https://support.google.com/chrome/answer/95464?hl=es |
| Incognito | Incógnito | browser | verified | yes | Chrome: modo Incógnito |
| Private window | ventana privada | platform | verified | yes | Safari |
| Private Browsing | Navegación privada | platform | verified | yes | Safari |
| Reopen Closed Window | Volver a abrir la ventana cerrada | browser | unverified | yes | Chrome wording not fetched; Safari: Volver a abrir la última ventana cerrada |
| Recently Closed | Cerradas recientemente | menu | verified | yes | Safari History menu |
| Show All History | Mostrar todo el historial | menu | verified | yes | Safari History menu |
| Clear History… | Borrar historial… | menu | verified | yes | Safari History menu |
| Show Next Tab | Mostrar pestaña siguiente | menu | verified | yes | Safari Window menu |
| Show Previous Tab | Mostrar pestaña anterior | menu | verified | yes | Safari Window menu |
| Duplicate Tab | Duplicar pestaña | menu | verified | yes | Safari |
| Pin Tab | Anclar pestaña | menu | verified | yes | Safari; https://support.apple.com/es-es/guide/safari/ibrw0495694f/mac |
| Unpin Tab | Desanclar pestaña | menu | verified | yes | Safari |
| Mute Tab | Silenciar pestaña | browser | verified | yes | Safari |
| Unmute Tab | Activar el sonido de la pestaña | browser | verified | yes | Safari |
| Move Tab to New Window | Trasladar pestaña a una nueva ventana | menu | verified | yes | Safari Window menu |
| Merge All Windows | Fusionar todas las ventanas | menu | verified | yes | Safari Window menu |
| Developer Tools | Herramientas para desarrolladores | browser | standard | yes | Chrome: Más herramientas › Herramientas para desarrolladores |
| Inspect Element | Inspeccionar elemento | menu | verified | yes | WebKit context menu |
| JavaScript Console | Consola de JavaScript | browser | verified | yes | Safari: Mostrar consola de JavaScript |
| View Page Source | Ver código fuente de la página | browser | standard | yes | Chrome; Safari's Show Page Source is Mostrar código fuente de la página |
| Keyboard Shortcuts | Atajos de teclado | platform | verified | yes | System Settings › Teclado |
| Check for Updates… | Buscar actualizaciones… | menu | standard | yes | common app menu item |
| Share… | Compartir… | menu | verified | yes | Safari File menu |
| Tab | pestaña | platform | verified | no | browser tab; plural pestañas; the key is Tab or tabulador |
| Tabs | pestañas | platform | verified | yes | Safari |
| Window | ventana | platform | verified | no | noun |
| Tab group | grupo de pestañas | platform | verified | yes | Safari; plural grupos de pestañas |
| Favorites | Favoritos | platform | verified | yes | Safari; barra de favoritos |
| Favorite | favorito | platform | verified | no | singular; adjective favorito/favorita |
| Bookmarks | Marcadores | platform | verified | yes | Safari menu |
| Bookmark | marcador | platform | verified | yes | Safari noun |
| Add Bookmark | Añadir marcador | menu | verified | yes | Safari; the menu item is Añadir marcador… |
| History | historial | platform | verified | no | browsing history noun |
| Downloads | Descargas | platform | verified | yes | Safari |
| Download | descarga | platform | standard | no | noun; verb descargar |
| Picture in Picture | Imagen dentro de imagen | platform | verified | yes | WebKit; Activar imagen dentro de imagen |
| Split View | Split View | platform | verified | yes | Apple keeps English; https://support.apple.com/es-es/guide/mac-help/mh14112/mac |
| Full Disk Access | Acceso total al disco / Acceso completo al disco | platform | verified | yes | shipped UI says total; help page https://support.apple.com/es-es/149699 says completo |
| Privacy & Security | Privacidad y seguridad | platform | verified | yes | System Settings pane |
| System Settings | Ajustes del Sistema | platform | verified | yes | the macOS app |
| Settings | Ajustes | platform | verified | yes | Apple; not Configuración or Preferencias |
| Settings… | Ajustes… | menu | verified | yes | app menu |
| General | General | platform | verified | no | Settings tab |
| Appearance | Aspecto | platform | verified | yes | System Settings pane |
| Advanced | Avanzado | platform | verified | no | Safari Settings tab |
| Extensions | Extensiones | platform | verified | yes | Safari Settings tab |
| Extension | extensión | platform | verified | no | singular |
| Passwords | Contraseñas | platform | verified | yes | Safari Settings tab and app name |
| Apple Passwords | Contraseñas | platform | verified | yes | app name: la app Contraseñas; https://support.apple.com/es-es/guide/passwords/welcome/mac |
| Keychain | llavero | platform | verified | yes | plural llaveros |
| Keychain Access | Acceso a Llaveros | platform | verified | yes | https://support.apple.com/es-es/guide/keychain-access/welcome/mac |
| Profile | perfil | platform | verified | yes | Safari |
| Profiles | perfiles | platform | verified | yes | Safari |
| Sidebar | barra lateral | platform | verified | yes | Safari |
| Show Sidebar | Mostrar barra lateral | menu | verified | yes | View menu |
| Hide Sidebar | Ocultar barra lateral | menu | verified | yes | View menu |
| Toggle Sidebar | Mostrar/ocultar barra lateral | browser | decided | yes | Apple's Mostrar/Ocultar pattern joined with a slash |
| Reader | Lector | platform | verified | no | Safari; Mostrar lector |
| Reading Mode | Modo Lectura | browser | verified | yes | Chrome; https://support.google.com/chrome/answer/14218344?hl=es |
| Reading List | Lista de lectura | platform | verified | yes | Safari |
| Website | sitio web | platform | verified | yes | Safari |
| Websites | Sitios web | platform | verified | yes | Safari Settings tab |
| Site | sitio | browser | standard | no | short form of sitio web |
| Site Settings | Ajustes del sitio | browser | decided | yes | Chrome says Configuración de sitios; Arx follows Apple's Ajustes |
| Permissions | Permisos | browser | verified | yes | Chrome site settings |
| Allow | Permitir | ui | verified | no | Safari |
| Don't Allow | No permitir | ui | verified | yes | Apple |
| Always Allow | Permitir siempre | ui | verified | yes | Safari |
| Allow Once | Permitir una vez | ui | verified | yes | Safari |
| Ask | Preguntar | ui | verified | no | Safari permission option |
| Block | Bloquear | ui | standard | no | permission option; Safari's Deny is Denegar |
| Camera | Cámara | platform | verified | yes | System Settings › Privacidad |
| Microphone | Micrófono | platform | verified | yes | System Settings › Privacidad |
| Location | Ubicación / Localización | platform | verified | no | site permission Ubicación (Safari); the system service is Localización |
| Notifications | Notificaciones | platform | verified | yes | System Settings pane |
| Cookies | Cookies | browser | verified | no | Safari; las cookies |
| Cache | caché | browser | verified | no | la caché |
| Clear Cache | Vaciar caché | browser | standard | yes | Safari's Develop item is Vaciar cachés |
| Clear History | Borrar historial | browser | verified | yes | Safari |
| Browsing data | datos de navegación | browser | verified | yes | Chrome: Eliminar datos de navegación |
| Autofill | Autorrelleno | platform | verified | yes | Safari AutoFill |
| Passkey | llave de acceso | platform | verified | yes | Apple |
| Passkeys | llaves de acceso | platform | verified | yes | Apple |
| Sign in | Iniciar sesión | ui | verified | no | verb |
| Sign-in | inicio de sesión | ui | standard | no | noun |
| Sign Out | Cerrar sesión | ui | verified | yes | Apple |
| Account | Cuenta | ui | verified | no | Apple |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | verified | yes | never translated |
| Mission Control | Mission Control | platform | verified | yes | never translated |
| Spaces (macOS) | Spaces / Space / espacio | platform | verified | no | UI keeps Spaces; prose says un Space or espacio; never use for Arx spaces |
| Desktop | escritorio | platform | verified | no | Escritorio y Dock |
| Dock | Dock | platform | verified | yes | never translated |
| Finder | Finder | platform | verified | yes | never translated |
| Menu bar | barra de menús | platform | verified | yes | Apple |
| Language & Region | Idioma y región | platform | verified | yes | System Settings pane |
| Translate | Traducir | platform | verified | no | Safari |
| Translation | Traducción | platform | verified | no | Safari |
| Default browser | navegador por omisión | platform | verified | yes | Apple Spain says por omisión, not predeterminado |
| Default web browser | Navegador web por omisión | platform | verified | yes | System Settings › Escritorio y Dock |
| Applications | Aplicaciones | platform | verified | no | the Applications folder |
| Move to Applications | Trasladar a la carpeta Aplicaciones | ui | decided | yes | Apple's Trasladar for moving |
| Login Items | Ítems de inicio | platform | verified | yes | System Settings: Ítems de inicio y extensiones |
| Battery Saver | Ahorro de energía | browser | verified | yes | Chrome Energy Saver; https://support.google.com/chrome/answer/12929150?hl=es |
| Memory Saver | Ahorro de memoria | browser | verified | yes | Chrome |
| Address | dirección | browser | verified | no | Safari |
| URL | URL | browser | standard | yes | feminine: la URL |
| Link | enlace | browser | verified | no | Apple; not vínculo |
| Links | enlaces | browser | verified | no | Apple |
| Copy Link | Copiar enlace | menu | verified | yes | Safari context menu |
| Open Link in New Tab | Abrir enlace en una pestaña nueva | menu | verified | yes | Safari context menu |
| Open Link in New Window | Abrir enlace en una ventana nueva | menu | verified | yes | WebKit context menu |
| Download Linked File | Descargar archivo enlazado | menu | verified | yes | WebKit context menu |
| Copy Image | Copiar imagen | menu | verified | yes | WebKit context menu |
| Save Image As… | Guardar imagen como… | menu | verified | yes | Safari |
| Look Up | Consultar “%@” | menu | verified | no | AppKit: Consultar “%@” |
| Search with Google | Buscar con Google | menu | verified | yes | pattern Buscar con %@ |
| Back | Atrás | browser | verified | no | Safari |
| Forward | Adelante | browser | verified | no | Safari |
| Home | Inicio | browser | verified | no | Safari |
| Search | Buscar / Búsqueda | ui | verified | no | verb Buscar, noun Búsqueda |
| Search engine | buscador | browser | verified | yes | Safari; not motor de búsqueda |
| Find on Page | Buscar en la página | browser | standard | yes | Safari help: Buscar en la página web actual |
| Page | página | browser | standard | no | web page |
| Pages | páginas | browser | standard | no | |
| Web page | página web | browser | verified | yes | Apple |
| Media | contenido multimedia | browser | verified | no | Safari |
| Video | Vídeo | ui | standard | no | Spain spelling with accent |
| Mute | Silenciar | browser | verified | no | Safari |
| Unmute | Activar sonido | browser | verified | no | Safari |
| Play | Reproducir | ui | verified | no | WebKit media control |
| Pause | Pausa / Pausar | ui | verified | no | noun Pausa, button verb Pausar |
| Cast | Enviar | browser | verified | no | Chrome: Enviar…, under Enviar, guardar y compartir |
| Screenshot | Captura de pantalla | platform | verified | yes | the Screenshot app |
| Capture | Captura | ui | standard | no | page capture; verb Capturar |
| Print | Imprimir | ui | verified | no | |
| Share | Compartir | platform | verified | no | |
| Open | Abrir | ui | verified | no | verb |
| Close | Cerrar | ui | verified | no | verb |
| Save | Guardar | ui | verified | no | |
| Cancel | Cancelar | ui | verified | no | |
| Done | Aceptar | ui | verified | no | Apple Spain's Done button is Aceptar, not Hecho or Listo |
| OK | Aceptar | ui | verified | no | |
| Delete | Eliminar | ui | verified | no | not Borrar (Borrar is Clear) |
| Remove | Eliminar | ui | verified | no | Apple uses Eliminar for Remove too |
| Rename | Renombrar | ui | verified | no | |
| Rename… | Renombrar… | ui | verified | no | |
| Add | Añadir | ui | verified | no | not Agregar |
| Edit… | Editar… | ui | verified | no | |
| Import | Importar | ui | verified | no | |
| Export | Exportar | ui | verified | no | |
| Install | Instalar | ui | verified | no | |
| Uninstall | Desinstalar | ui | verified | no | |
| Update | Actualizar | ui | verified | no | verb; noun actualización |
| Restore | Restaurar | ui | verified | no | |
| Reset | Restablecer | ui | standard | no | |
| Clear | Borrar | ui | verified | no | |
| Turn On | Activar | ui | verified | no | |
| Turn Off | Desactivar | ui | verified | no | |
| On | Activado | ui | verified | no | switch state; agrees: activada |
| Off | Desactivado | ui | verified | no | switch state; agrees: desactivada |
| Show | Mostrar | ui | verified | no | |
| Hide | Ocultar | ui | verified | no | |
| Move | Trasladar | ui | verified | no | Apple Spain; Mover is acceptable in sentences |
| Choose… | Seleccionar… | ui | verified | no | Apple Spain; not Elegir… |
| Continue | Continuar | ui | verified | no | |
| Try Again | Reintentar | ui | verified | no | |
| Not Now | Ahora no | ui | verified | no | |
| Learn More | Más información | ui | verified | no | |
| Default | Por omisión | ui | verified | no | Apple Spain; not Predeterminado |
| None | Ninguno | ui | verified | no | agrees: Ninguna |
| Always | Siempre | ui | verified | no | |
| Never | Nunca | ui | verified | no | |
| Name | Nombre | ui | verified | no | |
| Folder | carpeta | platform | verified | no | |
| New Folder | Nueva carpeta | menu | verified | yes | |
| Archive | Archivar / archivo | ui | verified | no | verb Archivar (Mail); avoid the noun next to the File menu |
| Archived | Archivado | ui | verified | no | agrees: archivada, archivadas |
| Theme | Tema | ui | verified | no | |
| Color | Color | ui | verified | no | |
| Icon | Icono | ui | verified | no | Spain: icono, not ícono |
| Light | Claro | platform | verified | no | appearance |
| Dark | Oscuro | platform | verified | no | appearance |
| Automatic | Automático | platform | verified | no | appearance |
| System | Sistema | ui | standard | no | |
| Shortcut | atajo | ui | standard | no | keyboard shortcut: atajo de teclado |
| Shortcuts | atajos | ui | verified | no | |
| Command | comando | ui | standard | no | |
| Assistant | asistente | ui | standard | no | |
| Agent | agente | ui | standard | no | |
| Chat | Chat | ui | unverified | no | AI chat; Apple has no fixed term |
| Chats | Chats | ui | unverified | no | |
| Report a Problem… | Informar de un problema… | ui | verified | yes | Safari: Informar de un problema… |
| Crash reports | informes de fallos | ui | unverified | yes | |
| Developer | Desarrollador | ui | verified | no | Safari Settings tab |
| Element | elemento | ui | verified | no | Inspeccionar elemento |
| Proxy | proxy | browser | verified | no | plural proxies (System Settings) |
| Arx | Arx | arx | verified | yes | brand, never translated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | sección | arx | decided | yes | feminine; never Space or espacio (Apple's words for macOS Spaces) |
| Spaces | secciones | arx | decided | yes | plural of sección |
| Space root | raíz de la sección | arx | decided | yes | rarely shown |
| Pinned tab | pestaña anclada | arx | verified | yes | Safari's pinned tab |
| Favorite tab | pestaña favorita | arx | decided | yes | same word as Favoritos |
| Regular tab | pestaña normal | arx | decided | yes | neither pinned nor favorite |
| Bookmark Tab | Añadir pestaña a marcadores | arx | decided | yes | menu item; uses marcador |
| Tab Archive | Pestañas archivadas | arx | decided | yes | descriptive; avoids Archivo, the File menu |
| Clean Copy | Copia limpia | arx | decided | yes | copy without tracking parameters |
| Copy Clean Link | Copiar enlace limpio | arx | decided | yes | |
| Clean Link | Enlace limpio | arx | decided | yes | |
| Original Link | Enlace original | arx | decided | yes | |
| Proxy Link | Enlace proxy | arx | decided | yes | |
| Copy Proxy Link | Copiar enlace proxy | arx | decided | yes | |
| PiP | PiP | arx | decided | yes | keep PiP |
| Page PiP | PiP de página | arx | decided | yes | page + PiP |
| Command Bar | Barra de comandos | arx | decided | yes | like barra lateral |
| Media | Multimedia | arx | decided | no | SideMenu tab; short label |
| SideMenu | menú lateral | arx | decided | no | not in UI text |
| Site menu | Menú del sitio | arx | decided | yes | |
| urlbar | dirección | arx | decided | no | not in UI text; never barra de direcciones |
| Empty page | Página vacía | arx | decided | yes | |
| Routing rule | Regla de apertura | arx | decided | yes | rule choosing where a link opens |
| Search shortcut | Atajo de búsqueda | arx | decided | yes | |
| bang | bang | arx | decided | yes | keep English |
| Badge | globo | arx | verified | yes | Apple's word: Globos (Notifications) |
| Organization | Organización | arx | decided | no | how tabs are arranged; policy text "your organization" is tu organización too |
| Browser data | Datos del navegador | arx | decided | yes | |
| Link Status | Estado de los enlaces | arx | decided | yes | Settings section |
| Live Calendar | Calendario en directo | arx | decided | yes | Spain: en directo, not en vivo |
| Setup Guide | Guía de configuración | arx | decided | yes | |
| Chrome Web Store | Chrome Web Store | arx | standard | yes | Google keeps the English name |
| WebKit | WebKit | arx | verified | yes | never translated |
| Chromium | Chromium | arx | verified | yes | never translated |
| MCP | MCP | arx | verified | yes | never translated |
| Arx Manual | Manual de uso de Arx | arx | decided | yes | Apple's pattern: Manual de uso de Contraseñas |
| Arx Assistant | Asistente de Arx | arx | decided | yes | |
