# Glossary: French (fr)

Translators of Arx into French use these terms. A term here wins over any other choice.

## Language rules

- Address: formal "vous", as Apple's French macOS and Safari do ("vous pouvez importer automatiquement vos signets"). Imperatives use the vous form ("Ouvrez", "Choisissez"). Verified: https://support.apple.com/fr-fr/guide/safari/ibrw1015/mac
- Sources: rows marked verified were checked on Apple's French support pages, on Google's French Chrome help, or against the French strings that ship in Safari, AppKit and System Settings on macOS (the exact UI text Apple uses). Where a help page and the shipped UI differ, the shipped UI wins.
- Capitalization: sentence case everywhere, menus and buttons included: only the first word and proper names take a capital ("Nouvelle fenêtre privée", "Afficher l’onglet suivant"). Product names keep their capitals (Safari, Mission Control, Split View, Arx).
- Punctuation and ellipsis: use Apple's single ellipsis character … (U+2026), never three dots, with no space before it ("Réglages…"). Put a non-breaking space (U+00A0) before : ; ! ? and inside guillemets: « texte ». Use guillemets « » for quoted UI names, as Apple does ("Rechercher « %@ »"). Use the typographic apostrophe ’ (U+2019), as Apple does ("l’onglet").
- Elision: "de" and "le/la" elide before Arx: "À propos d’Arx", "Quitter Arx", "l’assistant Arx".
- Plural categories: one, many, other. French "one" covers 0 and 1 ("0 onglet", "1 onglet"); "many" is for very large round numbers ("1 000 000 d’onglets").
- Numbers: a non-breaking (narrow) space groups thousands (1 000), the decimal separator is a comma.
- macOS Spaces: Apple's settings keep "Spaces" in English ("Les écrans disposent de Spaces distincts", "barre Spaces"); help prose calls one "un espace" ("Lorsque vous travaillez dans un espace, seules les fenêtres qui le composent sont visibles."). Verified: https://support.apple.com/fr-fr/guide/mac-help/mh14112/mac
- Arx space: "section" (feminine: "une section", "Nouvelle section", "Sections"), because a space is a page of the sidebar and the word cannot be confused with Apple's "espace"/"Spaces", nor with "zone", which Arx needs for capture areas ("Capturer une zone…"). Where English says "section" for something else (e.g. "the Developer section of Settings"), translate it as "rubrique".
- Buttons and menu items: infinitive verbs ("Ajouter", "Fermer l’onglet"), never the imperative. Menu items name the object with an article as Apple does ("Fermer l’onglet", "Dupliquer l’onglet").
- Tab: always "onglet" (masculine). The keyboard key Tab is "Tab" or "tabulation", never "onglet".
- Settings: Apple's word is "Réglages" (app settings, System Settings = "Réglages Système"). Use "Paramètres" only where the text names Chrome's own pages.
- Length: French runs about 20 to 30 percent longer than English; keep button labels short and prefer Apple's short forms.

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | Fichier | menu | verified | no | Safari menu bar |
| Edit | Édition | menu | verified | no | menu bar title; verb is Modifier |
| View | Présentation | menu | verified | no | menu bar title; the verb "view" is Afficher |
| History | Historique | menu | verified | no | Safari menu bar |
| Window | Fenêtre | menu | verified | no | menu bar title |
| Help | Aide | menu | verified | no | app Help menu is Aide Arx |
| Services | Services | menu | verified | no | app menu |
| About Arx | À propos d’Arx | menu | verified | yes | pattern of À propos de Safari, with elision |
| Hide Arx | Masquer Arx | menu | verified | yes | pattern of Masquer Safari |
| Hide Others | Masquer les autres | menu | verified | yes | Mail, Dictionnaire, Raccourcis; Safari alone says Masquer les autres apps |
| Show All | Tout afficher | menu | verified | yes | app menu |
| Quit Arx | Quitter Arx | menu | verified | yes | pattern of Quitter Safari |
| Undo | Annuler | menu | verified | no | Edit menu; also the Cancel button word |
| Redo | Rétablir | menu | verified | yes | Edit menu |
| Cut | Couper | menu | verified | no | Edit menu |
| Copy | Copier | menu | verified | no | Edit menu |
| Paste | Coller | menu | verified | no | Edit menu |
| Paste and Match Style | Coller et adapter le style | menu | verified | yes | Edit menu |
| Select All | Tout sélectionner | menu | verified | yes | Edit menu |
| Find | Rechercher | menu | verified | no | Edit menu submenu; Find… is Rechercher… |
| Use Selection for Find | Rechercher la sélection | menu | verified | yes | Edit › Rechercher |
| Jump to Selection | Aller à la sélection | menu | verified | yes | Edit › Rechercher |
| Spelling and Grammar | Orthographe et grammaire | menu | verified | yes | Edit submenu |
| Show Spelling and Grammar | Afficher l’orthographe et la grammaire | menu | verified | yes | AppKit menu |
| Check Document Now | Vérifier le document maintenant | menu | verified | yes | AppKit menu |
| Check Grammar With Spelling | Vérifier la grammaire et l’orthographe | menu | verified | yes | AppKit menu |
| Correct Spelling Automatically | Corriger l’orthographe automatiquement | menu | verified | yes | AppKit menu |
| Substitutions | Substitutions | menu | verified | no | Edit submenu |
| Smart Links | Liens intelligents | menu | verified | yes | Edit › Substitutions |
| Transformations | Transformations | menu | verified | no | Edit submenu |
| Make Upper Case | Tout en majuscules | menu | verified | yes | Safari; Mail writes Mettre en majuscule |
| Make Lower Case | Tout en minuscules | menu | verified | yes | Safari; Mail writes Mettre en minuscule |
| Capitalize | Première lettre en majuscule | menu | verified | yes | Safari; Mail and WebKit write 1re lettre majuscule |
| Minimize | Minimiser | menu | verified | yes | Window menu |
| Zoom | Réduire/agrandir | menu | verified | no | Window menu (window zoom), not page zoom |
| Bring All to Front | Tout ramener au premier plan | menu | verified | yes | Window menu |
| Enter Full Screen | Activer le mode plein écran | menu | verified | yes | AppKit menu |
| Exit Full Screen | Quitter le mode plein écran | menu | verified | yes | AppKit menu |
| Full Screen | plein écran | platform | verified | yes | "en plein écran"; AppKit menu title Plein écran |
| Zoom In | Zoom avant | menu | verified | yes | Safari View menu |
| Zoom Out | Zoom arrière | menu | verified | yes | Safari View menu |
| Actual Size | Taille réelle | menu | verified | yes | Safari View menu |
| Reload Page | Recharger la page | menu | verified | yes | Safari View menu |
| Reload | Recharger | browser | verified | yes | Safari |
| Stop Loading | Arrêter le chargement | menu | standard | yes | Safari's item is just Arrêter |
| Print… | Imprimer… | menu | verified | yes | File menu |
| Page Setup… | Format d’impression… | menu | standard | yes | File menu |
| Save Page As… | Enregistrer la page sous… | menu | standard | yes | Chrome; Safari's item is Enregistrer sous… |
| Open File… | Ouvrir un fichier… | menu | verified | yes | Safari File menu |
| Close Window | Fermer la fenêtre | menu | verified | yes | AppKit menu |
| Close Tab | Fermer l’onglet | menu | verified | yes | Safari File menu |
| New Window | Nouvelle fenêtre | menu | verified | yes | Safari File menu |
| New Tab | Nouvel onglet | menu | verified | yes | Safari File menu |
| New Private Window | Nouvelle fenêtre privée | menu | verified | yes | Safari File menu |
| New Incognito Window | Nouvelle fenêtre de navigation privée | browser | verified | yes | Chrome; https://support.google.com/chrome/answer/95464?hl=fr |
| Incognito | navigation privée | browser | verified | no | Chrome's French name for Incognito; same words as Safari's Private Browsing |
| Private window | fenêtre privée | platform | verified | yes | Safari |
| Private Browsing | Navigation privée | platform | verified | yes | Safari |
| Reopen Closed Window | Rouvrir la fenêtre fermée | browser | standard | yes | Chrome; Safari says Rouvrir la dernière fenêtre ayant été fermée |
| Recently Closed | Récemment fermés | menu | verified | yes | Safari History menu |
| Show All History | Afficher tout l’historique | menu | verified | yes | Safari History menu |
| Clear History… | Effacer l’historique… | menu | verified | yes | Safari History menu |
| Show Next Tab | Afficher l’onglet suivant | menu | verified | yes | Safari Window menu |
| Show Previous Tab | Afficher l’onglet précédent | menu | verified | yes | Safari Window menu |
| Duplicate Tab | Dupliquer l’onglet | menu | verified | yes | Safari |
| Pin Tab | Épingler l’onglet | menu | verified | yes | Safari; https://support.apple.com/fr-fr/guide/safari/ibrw0495694f/mac |
| Unpin Tab | Ne plus épingler l’onglet | menu | verified | yes | Safari |
| Mute Tab | Couper le son de l’onglet | browser | verified | yes | Safari |
| Unmute Tab | Réactiver le son de l’onglet | browser | verified | yes | Safari |
| Move Tab to New Window | Placer l’onglet dans une nouvelle fenêtre | menu | verified | yes | Safari Window menu |
| Merge All Windows | Fusionner toutes les fenêtres | menu | verified | yes | Safari Window menu |
| Developer Tools | Outils de développement | browser | verified | yes | Chrome: Plus d’outils › Outils de développement |
| Inspect Element | Inspecter l’élément | menu | verified | yes | WebKit context menu |
| JavaScript Console | Console JavaScript | browser | verified | yes | Safari: Afficher la console JavaScript |
| View Page Source | Afficher le code source de la page | browser | verified | yes | Safari's Show Page Source; Chrome uses the same French |
| Keyboard Shortcuts | Raccourcis clavier | platform | verified | yes | System Settings › Clavier |
| Check for Updates… | Rechercher les mises à jour… | menu | standard | yes | common app menu item |
| Share… | Partager… | menu | verified | yes | Safari File menu |
| Tab | onglet | platform | verified | no | browser tab; plural onglets; the key is Tab |
| Tabs | onglets | platform | verified | yes | Safari |
| Window | fenêtre | platform | verified | no | noun |
| Tab group | groupe d’onglets | platform | verified | yes | Safari; plural groupes d’onglets |
| Favorites | Favoris | platform | verified | yes | Safari; barre des Favoris |
| Favorite | favori | platform | verified | no | singular; adjective favori/favorite |
| Bookmarks | Signets | platform | verified | yes | Safari menu |
| Bookmark | signet | platform | verified | yes | Safari noun |
| Add Bookmark | Ajouter un signet | menu | verified | yes | Safari; the menu item is Ajouter un signet… |
| History | historique | platform | verified | no | browsing history noun |
| Downloads | Téléchargements | platform | verified | yes | Safari |
| Download | téléchargement | platform | standard | no | noun; verb télécharger |
| Picture in Picture | Image dans l’image | platform | verified | yes | WebKit; Activer le mode Image dans l’image |
| Split View | Split View | platform | verified | yes | Apple keeps English; https://support.apple.com/fr-fr/guide/mac-help/mh14112/mac |
| Full Disk Access | Accès complet au disque | platform | verified | yes | https://support.apple.com/fr-fr/149699 |
| Privacy & Security | Confidentialité et sécurité | platform | verified | yes | System Settings pane |
| System Settings | Réglages Système | platform | verified | yes | the macOS app |
| Settings | Réglages | platform | verified | yes | Apple; not Paramètres or Préférences |
| Settings… | Réglages… | menu | verified | yes | app menu |
| General | Général | platform | verified | no | Settings tab |
| Appearance | Apparence | platform | verified | yes | System Settings pane |
| Advanced | Avancés | platform | verified | no | Safari Settings tab |
| Extensions | Extensions | platform | verified | no | Safari Settings tab |
| Extension | extension | platform | verified | no | singular |
| Passwords | Mots de passe | platform | verified | yes | Safari Settings tab and app name |
| Apple Passwords | Mots de passe | platform | verified | yes | app name: l’app Mots de passe; https://support.apple.com/fr-fr/guide/passwords/welcome/mac |
| Keychain | trousseau | platform | verified | yes | plural trousseaux |
| Keychain Access | Trousseaux d’accès | platform | verified | yes | https://support.apple.com/fr-fr/guide/keychain-access/welcome/mac |
| Profile | profil | platform | verified | yes | Safari |
| Profiles | profils | platform | verified | yes | Safari |
| Sidebar | barre latérale | platform | verified | yes | Safari |
| Show Sidebar | Afficher la barre latérale | menu | verified | yes | View menu |
| Hide Sidebar | Masquer la barre latérale | menu | verified | yes | View menu |
| Toggle Sidebar | Afficher/masquer la barre latérale | browser | decided | yes | Apple's Afficher/Masquer pattern joined with a slash |
| Reader | Lecteur | platform | verified | no | Safari; Afficher le lecteur |
| Reading Mode | Mode Lecture | browser | verified | yes | Chrome; https://support.google.com/chrome/answer/14218344?hl=fr |
| Reading List | Liste de lecture | platform | verified | yes | Safari |
| Website | site web | platform | verified | yes | Safari |
| Websites | Sites web | platform | verified | yes | Safari Settings tab |
| Site | site | browser | standard | no | short form of site web |
| Site Settings | Réglages du site | browser | decided | yes | Chrome says Paramètres des sites; Arx follows Apple's Réglages |
| Permissions | Autorisations | browser | verified | yes | Chrome site settings |
| Allow | Autoriser | ui | verified | no | Safari |
| Don't Allow | Ne pas autoriser | ui | verified | yes | Apple |
| Always Allow | Toujours autoriser | ui | verified | yes | Safari |
| Allow Once | Autoriser une fois | ui | verified | yes | Safari |
| Ask | Demander | ui | verified | no | Safari permission option |
| Block | Bloquer | ui | standard | no | permission option; Safari's Deny is Refuser |
| Camera | Caméra | platform | verified | yes | System Settings › Confidentialité |
| Microphone | Micro | platform | verified | yes | Apple writes Micro, not Microphone |
| Location | Position / Service de localisation | platform | verified | no | site permission Position (Safari); the system service is Service de localisation |
| Notifications | Notifications | platform | verified | no | System Settings pane |
| Cookies | Cookies | browser | verified | no | Safari |
| Cache | Cache | browser | verified | no | le cache |
| Clear Cache | Vider le cache | browser | standard | yes | Safari's Develop item is Vider les caches |
| Clear History | Effacer l’historique | browser | verified | yes | Safari |
| Browsing data | données de navigation | browser | verified | yes | Chrome: Supprimer les données de navigation |
| Autofill | Remplissage automatique | platform | verified | yes | Safari AutoFill |
| Passkey | clé d’accès | platform | verified | yes | Apple |
| Passkeys | clés d’accès | platform | verified | yes | Apple |
| Sign in | Se connecter | ui | verified | no | verb |
| Sign-in | connexion | ui | standard | no | noun |
| Sign Out | Se déconnecter | ui | verified | yes | Apple |
| Account | Compte | ui | verified | no | Apple |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | verified | yes | never translated |
| Mission Control | Mission Control | platform | verified | yes | never translated |
| Spaces (macOS) | Spaces / espace / espaces | platform | verified | no | UI keeps Spaces; prose says un espace; never use for Arx spaces |
| Desktop | bureau | platform | verified | no | Bureau et Dock |
| Dock | Dock | platform | verified | yes | never translated |
| Finder | Finder | platform | verified | yes | never translated |
| Menu bar | barre des menus | platform | verified | yes | Apple |
| Language & Region | Langue et région | platform | verified | yes | System Settings pane |
| Translate | Traduire | platform | verified | no | Safari |
| Translation | Traduction | platform | verified | no | Safari |
| Default browser | navigateur par défaut | platform | verified | yes | Apple |
| Default web browser | Navigateur web par défaut | platform | verified | yes | System Settings › Bureau et Dock |
| Applications | Applications | platform | verified | no | the Applications folder |
| Move to Applications | Placer dans le dossier Applications | ui | decided | yes | Apple's Placer for moving, as in Placer l’onglet… |
| Login Items | Ouverture | platform | verified | no | System Settings: Ouverture et extensions |
| Battery Saver | Économiseur d’énergie | browser | verified | yes | Chrome Energy Saver; https://support.google.com/chrome/answer/12929150?hl=fr |
| Memory Saver | Économiseur de mémoire | browser | verified | yes | Chrome |
| Address | adresse | browser | verified | no | Safari |
| URL | URL | browser | standard | yes | feminine: une URL |
| Link | lien | browser | verified | no | Apple |
| Links | liens | browser | verified | no | Apple |
| Copy Link | Copier le lien | menu | verified | yes | Safari context menu |
| Open Link in New Tab | Ouvrir le lien dans un nouvel onglet | menu | verified | yes | Safari context menu |
| Open Link in New Window | Ouvrir le lien dans une nouvelle fenêtre | menu | verified | yes | WebKit context menu |
| Download Linked File | Télécharger le fichier lié | menu | verified | yes | WebKit context menu |
| Copy Image | Copier l’image | menu | verified | yes | WebKit context menu |
| Save Image As… | Enregistrer l’image sous… | menu | verified | yes | Safari |
| Look Up | Rechercher « %@ » | menu | verified | no | AppKit: Rechercher « %@ », non-breaking spaces inside « » |
| Search with Google | Rechercher avec Google | menu | verified | yes | pattern Rechercher avec %@ |
| Back | Page précédente / Précédent | browser | verified | no | Safari menu: Page précédente |
| Forward | Page suivante / Suivant | browser | verified | no | Safari menu: Page suivante |
| Home | Accueil | browser | verified | no | Safari |
| Search | Rechercher / Recherche | ui | verified | no | verb Rechercher, noun Recherche |
| Search engine | moteur de recherche | browser | verified | yes | Safari |
| Find on Page | Rechercher dans la page | browser | standard | yes | Safari help: Rechercher dans la page web active |
| Page | page | browser | standard | no | web page |
| Pages | pages | browser | standard | no | |
| Web page | page web | browser | verified | yes | Apple |
| Media | contenu multimédia | browser | verified | no | Safari |
| Video | Vidéo | ui | standard | no | |
| Mute | Couper le son | browser | verified | no | Safari |
| Unmute | Réactiver le son | browser | verified | no | Safari |
| Play | Lire | ui | verified | no | WebKit media control |
| Pause | Pause | ui | verified | no | WebKit media control |
| Cast | Caster | browser | verified | yes | Chrome: Caster…, under Caster, enregistrer et partager |
| Screenshot | Capture d’écran | platform | verified | yes | the Screenshot app |
| Capture | Capture | ui | standard | no | page capture; verb Capturer |
| Print | Imprimer | ui | verified | no | |
| Share | Partager | platform | verified | no | |
| Open | Ouvrir | ui | verified | no | verb |
| Close | Fermer | ui | verified | no | verb |
| Save | Enregistrer | ui | verified | no | not Sauvegarder |
| Cancel | Annuler | ui | verified | no | |
| Done | Terminé | ui | verified | no | button |
| OK | OK | ui | verified | no | |
| Delete | Supprimer | ui | verified | no | |
| Remove | Supprimer | ui | verified | no | Apple uses Supprimer for Remove too |
| Rename | Renommer | ui | verified | no | |
| Rename… | Renommer… | ui | verified | no | |
| Add | Ajouter | ui | verified | no | |
| Edit… | Modifier… | ui | verified | no | |
| Import | Importer | ui | verified | no | |
| Export | Exporter | ui | verified | no | |
| Install | Installer | ui | verified | no | |
| Uninstall | Désinstaller | ui | verified | no | |
| Update | Mettre à jour | ui | verified | no | verb; noun mise à jour |
| Restore | Restaurer | ui | verified | no | |
| Reset | Réinitialiser | ui | verified | no | |
| Clear | Effacer | ui | verified | no | |
| Turn On | Activer | ui | verified | no | |
| Turn Off | Désactiver | ui | verified | no | |
| On | Activé | ui | verified | no | switch state; agrees: activée |
| Off | Désactivé | ui | verified | no | switch state; agrees: désactivée |
| Show | Afficher | ui | verified | no | |
| Hide | Masquer | ui | verified | no | not Cacher |
| Move | Déplacer | ui | verified | no | |
| Choose… | Choisir… | ui | verified | no | |
| Continue | Continuer | ui | verified | no | |
| Try Again | Réessayer | ui | verified | no | |
| Not Now | Plus tard | ui | verified | no | |
| Learn More | En savoir plus | ui | verified | no | |
| Default | Par défaut | ui | verified | no | |
| None | Aucun | ui | verified | no | agrees: Aucune |
| Always | Toujours | ui | verified | no | |
| Never | Jamais | ui | verified | no | |
| Name | Nom | ui | verified | no | |
| Folder | dossier | platform | verified | no | |
| New Folder | Nouveau dossier | menu | verified | yes | |
| Archive | Archiver / archive | ui | verified | no | verb Archiver (Mail); noun archive |
| Archived | Archivé | ui | standard | no | agrees: archivée, archivés |
| Theme | Thème | ui | verified | no | |
| Color | Couleur | ui | verified | no | |
| Icon | Icône | ui | verified | no | feminine |
| Light | Clair | platform | verified | no | appearance |
| Dark | Sombre | platform | verified | no | appearance |
| Automatic | Automatique | platform | verified | no | appearance |
| System | Système | ui | standard | no | |
| Shortcut | raccourci | ui | standard | no | keyboard shortcut: raccourci clavier |
| Shortcuts | raccourcis | ui | verified | no | |
| Command | commande | ui | standard | no | |
| Assistant | assistant | ui | standard | no | |
| Agent | agent | ui | standard | no | |
| Chat | Discussion | ui | unverified | no | AI chat; Apple has no fixed term |
| Chats | Discussions | ui | unverified | no | |
| Report a Problem… | Signaler un problème… | ui | standard | yes | |
| Crash reports | rapports de plantage | ui | standard | yes | |
| Developer | Développeur | ui | verified | no | Safari Settings tab |
| Element | élément | ui | verified | no | Inspecter l’élément |
| Proxy | proxy | browser | verified | no | plural proxys (System Settings) |
| Arx | Arx | arx | verified | yes | brand, never translated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | section | arx | decided | yes | feminine; never espace (Apple's word for macOS Spaces) |
| Spaces | sections | arx | decided | yes | plural of section |
| Space root | racine de la section | arx | decided | yes | rarely shown |
| Pinned tab | onglet épinglé | arx | verified | yes | Safari's pinned tab |
| Favorite tab | onglet favori | arx | decided | yes | same word as Favoris |
| Regular tab | onglet ordinaire | arx | decided | yes | neither pinned nor favorite |
| Bookmark Tab | Mettre l’onglet en signet | arx | decided | yes | menu item; uses signet |
| Tab Archive | Onglets archivés | arx | decided | yes | descriptive, uses onglet |
| Clean Copy | Copie propre | arx | decided | yes | copy without tracking parameters |
| Copy Clean Link | Copier le lien propre | arx | decided | yes | |
| Clean Link | Lien propre | arx | decided | yes | |
| Original Link | Lien d’origine | arx | decided | yes | |
| Proxy Link | Lien proxy | arx | decided | yes | |
| Copy Proxy Link | Copier le lien proxy | arx | decided | yes | |
| PiP | PiP | arx | decided | yes | keep PiP |
| Page PiP | PiP de page | arx | decided | yes | page + PiP |
| Command Bar | Barre de commandes | arx | decided | yes | like barre latérale |
| Media | Médias | arx | decided | no | SideMenu tab; short label |
| SideMenu | menu latéral | arx | decided | no | not in UI text |
| Site menu | Menu du site | arx | decided | yes | |
| urlbar | adresse | arx | decided | no | not in UI text; never barre d’adresse |
| Empty page | Page vide | arx | decided | yes | |
| Routing rule | Règle d’ouverture | arx | decided | yes | rule choosing where a link opens; not redirection |
| Search shortcut | Raccourci de recherche | arx | decided | yes | |
| bang | bang | arx | decided | yes | keep English |
| Badge | pastille | arx | verified | yes | Apple's word: Pastilles (Notifications) |
| Organization | Organisation | arx | decided | no | how tabs are arranged; policy text "your organization" is votre organisation too |
| Browser data | Données du navigateur | arx | decided | yes | |
| Link Status | État des liens | arx | decided | yes | Settings section |
| Live Calendar | Calendrier en direct | arx | decided | yes | |
| Setup Guide | Guide de configuration | arx | decided | yes | |
| Chrome Web Store | Chrome Web Store | arx | standard | yes | Google keeps the English name |
| WebKit | WebKit | arx | verified | yes | never translated |
| Chromium | Chromium | arx | verified | yes | never translated |
| MCP | MCP | arx | verified | yes | never translated |
| Arx Manual | Guide d’utilisation d’Arx | arx | decided | yes | Apple's pattern: Guide d’utilisation de Safari |
| Arx Assistant | Assistant Arx | arx | decided | yes | |
