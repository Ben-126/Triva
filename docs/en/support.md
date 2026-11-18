<!-- English translation of docs/assistance.md: the French version is authoritative. -->

# Triva Support

*Last updated: 18 November 2026*

*This is a translation. The [French version](../assistance.md) is the authoritative one. Triva's screens are in French: the names of screens and buttons are given in English, followed by the French label in brackets.*

## Contact us

Write to **benpodro@gmail.com**. We answer as soon as we can, usually within a few days. Triva is made by a small family team, with no customer service department.

If you can, mention your device (iPhone, iPad or Mac), its system version, and the Triva version (at the bottom of Settings).

**Never put your API key in an email.** No one from Triva will ever ask you for it.

## Report a problem or some content

- **A wrong, shocking or dangerous answer**: in Triva, Settings > Report a Problem (« Réglages > Signaler un problème »), or write to **benpodro@gmail.com**. You can paste the question and the answer if you want: nothing is sent without you.
- **A bug**: describe what you were doing, what happened and what you expected.
- **A website or author** who doesn't want Triva to read their pages, or who thinks their content is misused: write to us, we will look at it quickly.

Because Triva has no server, the publisher cannot see your conversations: it can't find them or fix them remotely.

## Frequently asked questions

### Is Triva really free?

Yes: no price, no ads, no in-app purchases, no account. The only possible costs come from services that **you** connect with your own key (a cloud AI, Brave, Tavily): they bill you directly.

### Do I need an API key?

No. Without any key, Triva works with **Apple Intelligence** (on compatible devices) or a **Local Model (MLX)** (« Modèle local (MLX) ») that you download, and with free search engines.

A key is only needed if you want to use a cloud AI ("Personal API Key" engine, « Clé API personnelle », screen « Clés API ») or a paid search service (screen « Clés de recherche »: Brave, Tavily). You create the key yourself on the provider's website, and you follow its terms, **including its minimum age** (Tavily: 18).

### Where is my key stored? Who sees it?

In your device's **Keychain** (Apple's password vault). It is only sent to the provider concerned, directly from your device. Triva's publisher never sees it.

### What does Triva do with my data?

Nothing that goes through the publisher: **Triva has no server**, no ads, no analytics, no tracking. Your history stays on your device. To answer, Triva sends your question directly to the services needed (search engines, the AI you chose). Everything is detailed in the [privacy policy](privacy.md).

### What is the difference between the AI engines?

- **Apple Intelligence, on device** and **Local Model (MLX)**: the answer is written **on your device**. Your question is not sent to any outside AI (the web search itself always goes over the Internet).
- **Apple Intelligence, Apple's private cloud**: for requests too heavy for the device, Apple may process them on its secure servers.
- **Personal API Key**: the answer is written by the cloud provider you chose, with your key. Triva asks for your permission before the first time anything is sent.

The engine badge, on the search screen, always shows which AI engine is answering and whether your question is sent to an online AI.

### Local models (MLX) take up a lot of space

Yes, from a few hundred MB to several GB. You can delete them in Settings > MLX Models (« Modèles MLX »). They are downloaded from Hugging Face.

### How do I erase everything?

Settings, "Data" section (« Données ») > **Erase All** (« Tout effacer »): your history, favorites and caches are deleted from the device. Your keys, settings and local models are kept: delete them in « Clés API », « Clés de recherche » and « Modèles MLX ». Anything you already sent to an outside service must be erased with that service. Details: [privacy policy, section 7](privacy.md).

### What are "SearXNG instances"?

SearXNG is a free search engine that volunteers and non-profits run on their own servers (each server is an "instance"). By default Triva uses **public** instances and switches to another one if one doesn't answer. You can also add your own instance in Settings > Advanced > SearXNG Instances (« Réglages > Avancé > Instances SearXNG »).

To keep the list up to date, Triva sometimes downloads the public directory searx.space and tests a few instances with the word "test" (never your questions). You can turn this off in Settings > Advanced > Update the list automatically (« Mettre à jour la liste automatiquement »).

### Search doesn't work or is slow

Public instances are sometimes overloaded or block apps. Try again a bit later, add another instance, or use a Brave or Tavily key (« Clés de recherche ») for more reliable search.

### Why doesn't Triva read some websites?

Some websites ask automated programs not to read them, with a file called `robots.txt`. Triva honestly identifies itself as "Triva" and, when it reads sources automatically, **respects that refusal** (like the "noai" or "tdm-reservation" signals of some pages): it doesn't read those pages, but gives you their title, an excerpt from the search engine and their link. If you still want Triva to use one of these pages, tap **"Read this page"** (« Lire cette page ») under the source: Triva then reads it for you, like a browser.

Other websites block all apps, require a subscription or display their content in a way Triva can't read. Open the source link to see the page in Triva's built-in browser.

### Why doesn't Triva read one of my PDFs?

Some PDFs are **copy-protected** by their author. Triva reads a protected PDF only if it allows text extraction for accessibility (for example for screen readers). Otherwise, Triva doesn't read it at all, with any AI engine, and tells you that the file can't be read. There is no setting to override this: it is the file author's choice.

### I see adult content

By default, Triva asks search engines to filter this content (moderate level). Check that Settings > Advanced > Filter adult content (« Réglages > Avancé > Filtrer les contenus pour adultes ») is on. No filter is perfect: if shocking content gets through, report it.

### Triva gave me a wrong answer

It can happen: an AI can be wrong. Always check the cited sources, and report the answer. Triva does not replace a doctor, a lawyer or a financial adviser.

## Useful pages

- [Privacy policy](privacy.md)
- [Terms of Use](terms.md)
- [Legal Notice](legal-notice.md)
- [Licenses & Attributions](licenses.md)
- Triva source code: [github.com/Ben-126/Triva](https://github.com/Ben-126/Triva)
