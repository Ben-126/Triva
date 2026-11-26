<!-- English translation of docs/confidentialite.md: the French version is authoritative. -->

# Triva Privacy Policy

*Last updated: 26 November 2026*

*This is a translation. The [French version](../confidentialite.md) is the authoritative one. Triva's screens are in French: the names of screens and buttons are given in English, followed by the French label in brackets the first time.*

This page explains, in plain words, what Triva does with your data. It is written so that anyone can understand it, including a middle-school student.

## In short

- **Triva has no server.** Triva's publisher does not receive, see or keep **any** of your questions, answers or keys. (The only possible exception: anonymous crash reports passed on by Apple, if you agreed to it; see section 10.)
- **No account, no ads, no audience measurement, no tracking.** Triva contains no analytics or advertising tool.
- **What you do in Triva stays on your device** (iPhone, iPad or Mac), except what has to be sent over the Internet to answer your question and, if you leave **Handoff** on, the text of your question in progress and, if you pick up on another device, your conversation (see below).
- When Triva sends something over the Internet, it goes **directly** from your device to an outside service (a search engine, an AI you chose…). These services can see at least your device's **IP address**. Each one applies its own rules. They are all listed below.
- The **widget**, **Spotlight**, the **Live Activity**, **sharing** to Triva, **Siri** and **Shortcuts** work on your device: Triva sends none of it to its publisher. The first three are set in **Settings > Integrations** (« Réglages > Intégrations »), and section 2 shows exactly what they keep.
- **Handoff** (picking up your conversation in progress on another of your devices) is **on by default**: the text of your question in progress is then offered, by Apple's system, to your devices signed in to the same iCloud account; if you pick up on one of them, your **whole conversation** (your questions, the answers and their sources) is sent to it directly from your device and saved in its history. Triva does not send it to its publisher. You can turn it off in **Settings > Integrations** (see sections 2.1 and 3.8). <!-- à valider par Ben -->
- You can erase your history, favorites, caches and what Triva published in the widget, in Spotlight and in the Live Activity at any time in **Settings > Data > Erase All** (« Réglages > Données > Tout effacer »); your keys and local models are deleted in their own settings (see section 7).

## 1. Who publishes Triva?

Triva is published by **[Nom de l'éditeur]**, on a non-professional basis.

Contact for any question about your data: **benpodro@gmail.com**.

Triva is free, with no ads and no in-app purchases.

## 2. What stays on your device

This data is stored **only on your device**. The publisher has no access to it.

| Data | Where | How long |
|---|---|---|
| History: your questions, the answers, the sources found | The app's local database | Until you delete it |
| Favorites | The app's local database | Until you delete them |
| Settings (chosen AI engine, provider, model, your search instances, your permissions for cloud AIs…) | App settings (`UserDefaults`) | Until you change them or delete the app |
| Your API keys (cloud AI, Brave, Tavily) | The device Keychain (Apple's password vault) | Until you delete them in Settings > API Keys (« Clés API ») or Search Keys (« Clés de recherche ») |
| List of public search instances and their measured reliability | The app's internal storage | Updated as you use the app |
| Caches (recent pages and network responses, content of the Discover tab) | The app's internal storage | Renewed automatically; emptied by "Erase All" |
| Local AI models (MLX) you downloaded | The app's internal storage | Until you delete them in Settings > MLX Models (« Modèles MLX ») |
| Files you attach to a question (picked in Files, pasted, dragged and dropped, taken from the photo library or received through sharing) | The file is not sent anywhere else: its text is read on your device. For the preview and drag and drop, Triva keeps a temporary copy of the file, only on your device. It is erased when you remove the file, start a new conversation, close the window or use “Erase All”, and at the latest the next time Triva launches. No copy is kept above 200 MB (so no preview then). For an **image**, the text is read on your device (Vision): the image itself is never sent, and the recognized text follows the same rule as the text of a PDF. The **file name** and the **excerpts** used as sources of the answer are saved with it in the history (and in favorites if you add it there) | The copy: see the rule on the left. The name and excerpts: until you delete the conversation or the favorite, or "Erase All" |
| Pages you had read with "Read this page" (« Lire cette page ») | **In memory only** | Until Triva is closed or "Erase All" |
| Data of websites opened in the **built-in browser** (cookies, website data) | iPhone and iPad: storage of the built-in browser (Safari), separate for Triva. Mac: **nothing is kept** | iPhone and iPad: until the website deletes it, you use "Erase All" (which deletes it too) or you delete the app |

**Protection.** Triva adds no encryption of its own: your data is protected by your device's protection (passcode or password, built-in encryption on iPhone and iPad, FileVault on Mac if turned on). It is included in your device's **backups** (iCloud or computer), like other apps' data. One exception: the folder Triva shares with its widget and its share extension (see 2.1) is only a relay; Triva asks the system not to include it in backups.

### 2.1 Widget, Spotlight, Live Activity, sharing, Handoff

These features connect Triva to your device's system. None of them goes through a publisher's server. The first three, and Handoff, have a setting in **Settings > Integrations**.

| Feature | What is kept, and where | How long |
|---|---|---|
| **Last question in the widget** (« Dernière question dans le widget », off by default) | A small file in a folder shared between Triva and its widget (on your device): the **title** (80 characters at most), the identifier and the date of your **latest conversation**, never the text of an answer nor several conversations. While the setting is off, this file does not exist: the widget only shows the "New question" gesture. The widget reads this file, writes nothing and does not use the Internet. If you add it to the Lock Screen, the title may be readable without unlocking the device, unless you chose in iOS to hide sensitive content | Updated when your history changes; removed right away when you turn the setting off or use "Erase All" |
| **History in Spotlight** (« Historique dans Spotlight », on by default) | The **title** and **date** of your 500 most recent conversations, in your device's Spotlight index, which stays on the device. Never the text of questions or answers. Triva also notes in its settings the identifiers of what it indexed (without the titles), so it can remove them | Removed when you delete the conversation, turn the setting off or use "Erase All" |
| **Live Activity during a search** (« Activité en direct pendant une recherche », on by default; iPhone and iPad) | During a search, the stage ("Thinking…", "Searching for sources…", "Reading 3 sources", "Writing…", "Answer ready") and the number of sources, on the Lock Screen and in the Dynamic Island. Never the content of the model's reasoning: only the name of the stage. With **Show the question** (« Afficher la question », on by default, placed under "Live Activity"), your **question** also appears (one line, 140 characters at most); when it is off, no trace of your question is sent to the Live Activity, and the one in progress loses it right away. It starts only if Triva is open, updates from the device with no server and no push notification, and may also show, depending on your devices, on a paired watch, Mac or CarPlay. Your question, when it appears, can therefore be read without unlocking the device, unless you chose in iOS to hide sensitive content | Answer ready and Triva open: disappears right away. Answer ready and Triva in the background: 30 minutes at most. Search interrupted or failed: 5 minutes at most. Also removed when you turn the setting off (turning off only "Show the question" removes the question and keeps the stage), delete the conversation, use "Erase All", or the next time Triva launches |
| **Sharing to Triva** ("Search with Triva" in the share sheet; iPhone and iPad) | What you share (a text, a page address with its title, a PDF, a Word .docx document or an image) is placed in a folder shared between the share extension and Triva, on your device: 10 shares at most (beyond that, the oldest are erased and Triva tells you), 400 MB of files (PDF or Word up to 200 MB, image up to 50 MB). The text is limited to 2,000 characters and the file name is cleaned up. The extension sends nothing over the Internet and starts no search. The next time Triva comes to the foreground, every pending share is picked up, in order: the texts arrive one after the other in the input bar (never sent without you) and the files are attached to the question, within the limit of files per conversation (temporary copy, see above) | Erased from the shared folder as soon as Triva has picked it up; otherwise expired after 24 hours and erased the next time Triva or the extension runs; or by "Erase All". The extension's working folder (temporary folder) is erased at the end of the share or, at the latest, at the next share |
| **Handoff: pick up on another device** (« Continuer sur mes autres appareils », "Continue on my other devices", on by default; iPhone, iPad and Mac) | **Two things.** First the **announcement**: the text of your question in progress (the text in the input bar or, if there is none, your last question; 1,200 characters at most) and the identifier of your conversation. Triva hands them to the system, which offers them to your **other devices signed in to the same iCloud account** (Apple's Continuity feature). Then, **only if you pick up on the other device**, that device asks the device you come from for your **whole conversation**, which sends it directly: your questions and the answers already finished, with their sources (titles, addresses and excerpts), 200 messages at most and 2 MB at most (the oldest are left out if it is too much); an answer still being written is not sent. The other device saves it in its history, where it stays like your other conversations. Never: the attached files, your keys, the chosen engine or your settings. Triva gives this activity no title and puts it neither in Spotlight nor in Siri's suggestions. Nothing is sent to the publisher. Apple carries it: according to Apple's security guide, the announcement is encrypted with keys kept in your devices' keychain and protected like an iMessage; it travels over Bluetooth or, in some cases, through Apple's notification service; for larger content the guide describes a direct, encrypted Wi-Fi connection between the two devices (see 3.8). On the other device nothing happens without you: you choose to pick up, the conversation opens, the text you had typed arrives in the input bar after whatever is already there, and nothing is ever sent without you. If the conversation does not arrive, only the text of your question is picked up and Triva tells you <!-- à valider par Ben --> | As long as Triva's active window holds a conversation or this text and the setting is on. Nothing is offered or served any more when you turn the setting off (even if the other device asks afterwards), or when you delete the conversation. "Erase All" does not empty the input bar: text still in it keeps being offered. What another device has already received is a copy in its history: it is deleted there like any conversation, and "Erase All" on that device erases it too. How long Apple's system then offers the announcement on your other devices: it decides, not Triva |

On Mac, there is no share extension and no Live Activity (Handoff does work on Mac too). The folder shared with the widget is used only if you have turned on "Last question in the widget" at some point.

**Siri and Shortcuts.** Triva's actions ("Ask Triva a question" (« Poser une question à Triva »), "New search" (« Nouvelle recherche »), "Search the history" (« Chercher dans l'historique »), "Open a conversation" (« Ouvrir une conversation »), "Choose the answer mode" (« Choisir le mode de réponse »)) keep nothing beyond what is described here. A question asked through Siri or Shortcuts is saved in your history like the others. The conversations Siri and Shortcuts see are reduced to their title and date; "Search the history" also finds text in your messages, but returns only titles and dates, and requires the device to be unlocked. See also section 3.7.

**Pasting and photo library.** Pasting a file or an image (⌘V on Mac, "Paste" in the paperclip menu on iPhone and iPad) reads the clipboard only when you ask for it. For a photo, Triva has no access to your photo library: the system's photo picker opens, and Triva only receives the photos you choose in it. A pasted file or a photo then follows the same rule as any attached file (the "Files you attach" row above).

## 3. What goes over the Internet, and to whom

All of this is sent **directly from your device**. None of it goes through a server of the publisher. Each service receives at least your device's IP address and the time of the request.

### 3.1 Automatically, without you doing anything

| To whom | When | What is sent |
|---|---|---|
| **searx.space** (directory of public SearXNG instances) | When you open Triva, at most once every 24 hours (one hour after a failed connection) | Nothing but the request for the list |
| **A few public SearXNG instances** | When the list is downloaded (to check new instances), and each time you open Triva to retest at most 3 instances that were working badly | A test search, always the word "test". **None of your questions.** |

You can turn these checks off with the **"Update the list automatically"** setting (« Mettre à jour la liste automatiquement », Settings > Advanced).

### 3.2 When you ask a question

| To whom | When | What is sent |
|---|---|---|
| **SearXNG instances** (public ones, or the ones you added) | With each search | Your question (sometimes rephrased), the language, the type of search, the results page, the time range; "moderate" adult-content filter by default, which you can turn off in Settings > Advanced |
| **Open sources**: Wikipedia, OpenAlex, arXiv, Marginalia Search | Search, when useful | The words of your search |
| **Brave Search** or **Tavily** | Only if you entered your own key | The words of your search and your key |
| **The web pages found** (any website) | To read the sources of the answer | A request for the page, with a name that identifies Triva. For this automatic reading, Triva respects websites that refuse it (`robots.txt` file, or "noai" and "tdm-reservation" signals sent by the page). If you tap **"Read this page"** (« Lire cette page ») on a refused source, Triva reads it for you, like a browser, without applying that refusal. |
| **Open-Meteo** (weather) | When your question is about the weather | The name of the city you typed, then its coordinates |
| **Hosts of images and thumbnails, YouTube** | When image or video results are shown | The request for the image (as in a web browser) |

In your history, Triva only keeps the **title and link** of Brave results, as Brave's terms require.

### 3.3 The AI engine that writes the answer

You choose the engine yourself in Settings.

- **Apple Intelligence, on device** and **Local model (MLX)** (« Modèle local (MLX) »): the answer is written on your device. Nothing is sent to an outside AI.
- **Apple Intelligence, Apple's private cloud**: when the question is more than the device can handle, it may be processed by Apple's private cloud (Private Cloud Compute). According to Apple, nothing is kept there. See [Apple's privacy policy](https://www.apple.com/legal/privacy/).
- **Personal API key** (« Clé API personnelle », cloud AI): Triva sends the provider you chose, **using your key**: your question, the earlier messages of the conversation, excerpts from the pages found, and the text of the files you attach. For image and video searches, your question is also sent to it to be rephrased. Before the first message to each provider, Triva asks for your permission; you can withdraw it in Settings > API Keys.
- **Copy-protected PDFs** are read only if they allow text extraction for accessibility. Otherwise, Triva does not read them at all (neither on your device nor in the cloud) and tells you so.
- Some providers (OpenAI, Claude, Perplexity) can also **search the web** from your question, if you turn this mode on; it is billed to your account with them.
- To show the list of models or check your key, Triva also contacts that provider with your key.

### 3.4 When you download a local model

The model is downloaded from **Hugging Face**, which receives the name of the requested model and your IP address.

### 3.5 When you open a link

Links open in Triva's **built-in browser** (built-in Safari on iPhone and iPad, a web window on Mac). The website receives what it receives from any browser (IP address, request for the page) and may set cookies. Triva doesn't see or keep what you do on these websites. The website's own rules apply. On iPhone and iPad, "Erase All" also deletes the cookies and data of these websites.

### 3.6 When you open the Discover tab (« Découvrir »)

Triva downloads the news feeds of these publishers: Numerama, Frandroid, The Conversation, ESPN, Variety, Deadline, The Hollywood Reporter, ARTnews. They receive the request for the feed (and your IP address). The **article images** (except for The Conversation) are also downloaded from the servers of these publishers, or of those hosting their images, which then receive your IP address.

### 3.7 When you use Siri or Shortcuts

The widget, Spotlight, the Live Activity and sharing send nothing over the Internet by themselves. "Ask Triva a question" (Siri, Shortcuts) asks a real question: it follows the same path as a question asked in the app (sections 3.2 and 3.3), with the AI engine you chose. A question is never sent to a cloud AI without your permission for that provider: otherwise Triva asks you to open the app, and your question waits in the input bar. Triva hands back to Siri or Shortcuts (Apple) your question, the answer, and the title and link of the sources; what a shortcut does next with these depends on the shortcut you built. Siri and Shortcuts are Apple services, and Apple applies its own rules (see [Apple's privacy policy](https://www.apple.com/legal/privacy/)).

### 3.8 When you use Handoff

Handoff sends nothing to a service Triva chose: Apple's system carries, between your devices signed in to the same iCloud account, the announcement (the text of your question in progress and the identifier of your conversation, see 2.1) and then, if you pick up, your whole conversation. According to Apple's security guide on Handoff, your devices recognize each other through your iCloud account; each keeps in its keychain a key that encrypts and authenticates what it announces, and the content of the announcement is protected and transferred in the same way as an iMessage. It travels over Bluetooth; Apple states that, "in some situations", these messages are sent through its notification service (APNs) instead, so through its servers. For larger content, the same guide says some apps use Apple features that send the data over a direct Wi-Fi connection between the two devices: that connection is "encrypted (with TLS)", with an identity shared through iCloud Keychain and checked against yours. Triva sends your conversation through the Apple feature meant for this ("continuation streams", which Apple's documentation describes as a connection from the device that picks up back to the original device); the security guide does not name it, and what Triva can state about it stops there. The guide does not say whether Apple keeps a copy either: Apple's own rules apply (see [Apple's privacy policy](https://www.apple.com/legal/privacy/)). Triva's publisher receives nothing. On the device that picks up, the conversation is saved in the local history, like all the others. To turn it all off, turn off "Continue on my other devices" in **Settings > Integrations**; Handoff also has its own setting in your device's settings. <!-- à valider par Ben -->

## 4. Outside services follow their own rules

The services in section 3 are not controlled by Triva's publisher. Each decides what it keeps, for how long and in which country, under its own policy. Some are located **outside the European Union**, for example in the United States; **DeepSeek states that it stores data in China**. Some set a **minimum age**: for example, Tavily is for people aged 18 or over.

For the services you choose with **your own key** (cloud AI, Brave, Tavily), you are the one with an account there: their terms apply to you directly.

Privacy policies (addresses checked on November 14, 2026):

| Service | Policy |
|---|---|
| OpenAI | https://openai.com/policies/eu-privacy-policy/ (this policy does not cover content sent through the API: OpenAI's business terms apply, see https://openai.com/policies/) |
| Claude (Anthropic) | https://www.anthropic.com/legal/privacy |
| Google Gemini | https://policies.google.com/privacy and https://ai.google.dev/gemini-api/terms (with a free key, Google may use what you send to improve its products) |
| Perplexity | https://www.perplexity.ai/hub/legal/privacy-notice |
| Groq | https://groq.com/privacy-policy |
| OpenRouter | https://openrouter.ai/privacy (then passes what you send to the company running the chosen model) |
| Mistral | https://legal.mistral.ai/terms/privacy-policy |
| DeepSeek | https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html |
| xAI (Grok) | https://x.ai/legal/privacy-policy |
| Together AI | https://www.together.ai/privacy |
| Fireworks AI | https://fireworks.ai/privacy-policy |
| Cerebras | https://www.cerebras.ai/privacy-policy |
| Brave Search | https://api-dashboard.search.brave.com/privacy-policy |
| Tavily | https://www.tavily.com/privacy |
| Apple | https://www.apple.com/legal/privacy/ |
| Hugging Face | https://huggingface.co/privacy |
| Open-Meteo | https://open-meteo.com/en/terms |
| Wikipedia (Wikimedia) | https://foundation.wikimedia.org/wiki/Policy:Privacy_policy |
| arXiv | https://info.arxiv.org/help/policies/privacy_policy.html |
| Marginalia Search | https://about.marginalia-search.com/article/privacy/ |
| OpenAlex | https://openalex.org/privacy |
| searx.space and SearXNG instances | Each instance is run by a different person or organization, with its own rules. List: https://searx.space/ |

If you add a **custom provider** or your **own** search instance, you are the one choosing it: Triva doesn't know its rules.

## 5. Why these requests are made

- To **answer your question**: that is the service you ask Triva for.
- To **keep search reliable** (listing and testing instances): without it, many searches would fail. You can turn this off.

**Legal bases** (GDPR, article 6):

- what is sent to answer your question relies on **performing the service** you ask for by using Triva (see the [terms of use](terms.md));
- updating and testing instances relies on the **legitimate interest** in keeping search reliable; you can object by turning off "Update the list automatically";
- sending to a cloud AI relies on your **permission**, which you can withdraw at any time in Settings > API Keys.

You don't have to use these services: without a cloud AI or a key, Triva works with Apple Intelligence or a local model.

## 6. The publisher's role

The publisher receives none of your data. But the publisher designed Triva and chose the services used by default (public instances, open sources, automatic updates). **As a precaution, the publisher acts as the party responsible for these choices** under the European data protection regulation (GDPR): it informs you here, answers your questions, and collects nothing.

For what you decide to send yourself, with your own key or your own service, each provider is responsible for what it does with your data.

## 7. Erasing your data

- **Erase All** (« Tout effacer », Settings, "Data" section, « Données ») deletes at once, on this device: your history (conversations, messages, sources), your favorites, the network cache, the Discover tab cache, the temporary copies of attached files, what Triva published in the widget, in Spotlight and in the Live Activity, pending shares (iPhone and iPad) and, on iPhone and iPad, the cookies and data of websites opened in the built-in browser. Normally, the database is emptied completely and no trace of it remains. If that isn't possible, Triva deletes items one by one (leaving the same temporary traces as a single deleted conversation, see below) and tells you if part of it could not be erased.
- "Erase All" **does not delete**: your API keys, the chosen engine, provider and model, your permissions for cloud AIs, your search instances, your other settings (including those under "Integrations"), the downloaded local models. To delete them: Settings > API Keys (or Search Keys), and Settings > MLX Models.
- **Turning off** "Last question in the widget" or "History in Spotlight" (« Historique dans Spotlight ») removes what Triva had published right away; turning off "Live Activity" stops the one in progress, and turning off "Show the question" removes the question from the one in progress and from those waiting to disappear; turning off "Continue on my other devices" stops offering your question and your conversation to your other devices right away (what another device has already received no longer depends on Triva). If the system refuses a removal, Triva tries again a few times, and "Erase All" warns you when something could not be erased.
- A **single conversation you delete** disappears from the app right away (and from Spotlight; its finished Live Activity is removed). It may stay for a while in the database's internal file, still protected by your device's encryption, until that file is cleaned up automatically.
- **Deleting the app** removes its data from the device. Keys saved in the Keychain may sometimes remain after the app is deleted: delete them first in Triva's Settings.
- **Data of websites opened in the built-in browser** (cookies): on Mac, nothing is kept; on iPhone and iPad, "Erase All" deletes it too (deleting the app does as well).
- What you have **already sent** to an outside service (section 3) cannot be erased by Triva: ask that service directly. The same goes for what a shortcut you built saved elsewhere (a note, a file…).

## 8. Your rights

The GDPR gives you rights over your data: to **access** it, **correct** it, **erase** it, **object** to processing, **restrict** processing, **get it back** (portability), and **withdraw your permission** at any time.

- For data **on your device**, you use these rights yourself in the app: you see it, you delete it, you withdraw your permissions.
- For data sent to an **outside service**, contact that service (links in section 4).
- For any question, write to the publisher: **benpodro@gmail.com**. Since the publisher holds none of your data, it cannot send it to you or erase it for you, but it will help you find who to contact.
- You can also **file a complaint with the CNIL** (the French data protection authority): https://www.cnil.fr/fr/plaintes. If you live in another country, you can also contact your own data protection authority.

## 9. If you are under 15

In France, under 15, some uses of your data require a parent's permission as well as yours (French Data Protection Act, article 45). For Triva, this mainly concerns **cloud AIs**: if you are under 15, agree to sending data to a provider **together with a parent**. Also check the minimum age required by each service (section 4): some, like Tavily, are for adults only.

## 10. What Triva doesn't do

- No account or sign-up.
- No ads.
- No audience measurement or usage statistics. Triva itself sends no error reports. If you turned on sharing analytics with developers in your device settings, Apple may pass crash reports to the publisher without your identity.
- No tracking across apps or websites, no advertising identifier.
- No automated decisions about you: Triva makes no decision about you that would have legal effects or significantly affect you (GDPR, article 22).
- No selling or sharing of data by the publisher: it has none.
- No access to your location, contacts, microphone or camera, and no access to your whole photo library: to attach a photo, you pick it in the system's picker, and Triva only receives those. Triva only reads the files, images and texts you choose to attach, paste or share to Triva yourself. Triva may ask for access to the **local network**, only if you add a search instance hosted at home.

## 11. Changes to this policy

If Triva changes the way it handles your data, this page will be updated and its date will change. If a change concerns what is sent to a cloud AI, Triva will ask for your permission again in the app.

## Version history

| Version | Date | Changes |
|---|---|---|
| 1.0 | 18 November 2026 | First version. |
| 1.1 | 25 November 2026 | Added the widget, Spotlight, the Live Activity, sharing to Triva, Siri and Shortcuts, pasting and the photo library (sections 2.1, 3.7, 7 and 10); erasure rule for temporary copies of files. |
| 1.2 | 26 November 2026 | Added Handoff, including sending the whole conversation to the device that picks up (sections In short, 2.1, 3.8 and 7). |
