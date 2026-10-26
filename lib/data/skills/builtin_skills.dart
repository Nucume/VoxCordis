import 'booru_tags.dart';
import 'skills.dart';

/// The starter skills VoxCordis writes into a companion's folder the first
/// time. After that they are the human's to change, turn off or delete.
class BuiltInSkills {
  static const all = <BuiltInSkill>[
    proofreading,
    weather,
    priceWatch,
    morningBriefing,
    adhdSupport,
    booruTags,
  ];

  static final ids = {for (final s in all) s.id};

  static const proofreading = BuiltInSkill(
    id: 'proofreading',
    title: 'Proofreading',
    description:
        'Check a text your human wrote (an email, a message, a post, an '
        'essay) for spelling, grammar, tone and clarity, and give it back '
        'corrected.',
    body: '''
# Proofreading

1. Find the text: in their message, or in a file they shared ([file: …]).
   If there is none, ask them to paste it.
2. Keep their voice and meaning. Fix spelling, grammar, punctuation and
   words that are clearly wrong. Don't rewrite what is fine.
3. Keep the language they wrote in. Keep their formatting, names and
   numbers exactly.
4. Give back the whole corrected text first, in a code block, so it is easy
   to copy.
5. Below it, list the changes that matter in a few short lines (not every
   comma). Point out anything unclear, too blunt or too long as a
   suggestion, without changing it.
6. If they asked for a particular tone (more formal, friendlier, shorter),
   do that and say so.
''',
  );

  static const weather = BuiltInSkill(
    id: 'weather',
    title: 'Weather',
    description:
        'Look up the weather and forecast for a place, and say what to '
        'wear or bring.',
    body: '''
# Weather

1. Which place: the one they name, or where they live if you remember it.
   If you don't know, ask once, then remember it for next time.
2. You need the internet. If you have no web_search, tell them they can
   turn it on in Settings → Internet, and never guess the weather.
3. Call read_page on https://wttr.in/PLACE?format=4 (spaces in the place
   as +) for right now, or https://wttr.in/PLACE?0&T for today. If that
   doesn't work, web_search "weather PLACE today" and read the best result.
4. Answer in two or three sentences: now, the rest of today, and anything
   to watch for (rain, wind, heat, ice). Add tomorrow only if they asked.
5. Use what they're used to: °C and km/h unless they use °F or mph.
6. End with a practical tip in your own way: a jacket, an umbrella, water.
''',
  );

  static const priceWatch = BuiltInSkill(
    id: 'price-watch',
    title: 'Price watch',
    description:
        'Keep an eye on the price of something on a site, and tell your '
        'human when it drops or reaches their price.',
    body: '''
# Price watch

The watch list is price-watch.md in your folder. Each line:
`- ITEM | ADDRESS | wanted price | last price | date checked`

## When they ask you to watch something
1. Get the address of the product page and the price they hope for. If
   they gave only a name, web_search it and ask which result they mean.
2. read_page the address (or browse it if the page needs clicking) and find
   the current price. If you can't find a price, say so; don't guess.
3. Add a line to price-watch.md with read_file and write_file (or
   edit_file). Create the file if it doesn't exist.
4. If there is no daily check planned yet (list_schedule), call
   schedule_task with text "/price-watch check the watch list" and repeat
   "daily" at a time that suits them.
5. Tell them what it costs now and that you'll keep an eye on it.

## When the check runs
1. read_file price-watch.md, then read_page each address.
2. Update each line's last price and date.
3. Tell them only about what changed: a lower price, a price at or under
   what they wanted, sold out or back in stock. If nothing changed, one
   short line is enough.
4. Remove an item when they say they bought it or don't want it any more.
''',
  );

  static const morningBriefing = BuiltInSkill(
    id: 'morning-briefing',
    title: 'Morning briefing',
    description:
        'Give your human a short start to the day: weather, what is '
        'planned, a few headlines, and something to look forward to.',
    body: '''
# Morning briefing

Keep the whole briefing short, warm and easy to read on a phone-sized
glance: a greeting, then a few small parts with a line or two each.

1. **Weather**: today where they live (as the weather skill does: read_page
   https://wttr.in/PLACE?format=4). Skip it if you can't go online.
2. **Today**: call list_schedule and mention reminders and tasks due today.
   Add anything you remember they have on today or soon.
3. **News**: web_search for the top news where they live, or on topics
   they care about, and give three headlines in one line each. Leave it
   out if they told you they don't want news.
4. **One nice thing**: something to look forward to, a small idea for the
   day, or a kind word. Make it fit them, not generic.

If they want this every morning, call schedule_task with text
"/morning-briefing" and repeat "daily" (or "weekdays") at the time they
usually wake up.
''',
  );

  static const booruTags = BuiltInSkill(
    id: 'booru-tags',
    title: 'Booru tags',
    description:
        'Danbooru tag vocabulary and workflow for anime picture models '
        '(Anima, Animagine, Illustrious, Pony): read it before draw_picture, '
        'then open only the tag files the picture needs.',
    files: booruTagFiles,
    older: [_booruTagsV1],
    body: '''
# Danbooru-informed anime prompting

Danbooru is a human-maintained vocabulary and reference-search system, not a
universal prompt language. Its tags help name compact, visually grounded
concepts, especially for anime checkpoints trained on Danbooru-like
captions, but how a tag behaves depends on the model, its tokenizer, its
captions and when it was trained.

## Tag files: read only what you need

The real tag vocabulary is in files next to this one, one per tag group.
Don't guess tags: read_file the one or two files the picture needs (e.g.
skills/booru-tags/tags/hair-styles.md) and pick from them.

- tags/face.md: emotions, smiles, gazes, eye states, mouth, eyebrows
- tags/eyes.md: iris colors, pupils, eye shapes
- tags/hair-styles.md: length, braids, buns, ponytails, bangs
- tags/skin-color.md: natural and unnatural skin
- tags/image-composition.md: view angle, perspective, framing, styles
- tags/lighting.md: light direction, types, time of day, sources
- tags/posture.md: positions, movement, arms, legs, poses
- tags/hands.md: hands on self or someone else
- tags/gestures.md: hand and finger gestures
- tags/attire.md: tops, bottoms, footwear, uniforms, jewelry
- tags/dress.md, tags/legwear.md, tags/headwear.md, tags/eyewear.md,
  tags/neck-and-neckwear.md: those in detail
- tags/breasts.md, tags/ass.md: sizes, shapes, clothes, interactions
- tags/nudity.md: full and partial nudity
- tags/sexual-positions.md, tags/sex-acts.md: explicit scenes

## Core categories

- **artist**: creator of an individual image, not the franchise owner.
- **character**: named fictional character.
- **copyright**: source work/franchise.
- **general**: visible concepts: clothes, pose, composition, setting,
  color, visual attributes.
- **meta**: database/post information, not scene content.

An alias maps old names or spellings to a canonical tag; an implication
means a narrow tag implies a broader one. Neither is a guarantee the model
learned it, and a character tag doesn't add its series: write both.

## Workflow

1. Follow how the picture model wants prompts (draw_picture says so).
2. Start with a small set of unambiguous visual tags: who and how many
   (1girl, 1boy, solo), then looks, clothes, pose, place, light. For
   yourself, take your looks from personality.md.
3. Add composition and camera tags only as needed: upper body, full body,
   from above, looking at viewer.
4. Keep character, copyright, artist and style tags separate so their
   effects can be told apart.
5. Use negative tags sparingly: a tag the model never learned does nothing.
6. Rating: safe, sensitive, nsfw or explicit. Pick what your human asked
   for; when unsure, safe.

## In VoxCordis

- Lowercase, comma-separated, spaces instead of underscores.
- 15 to 40 tags is plenty. Don't repeat a tag.
- Brackets in a name are escaped: `hoshimachi suisei \\(1st costume\\)`.
- Quality tags (masterpiece, best quality…) are added for you; leave them
  out.
- What to avoid goes in negative_prompt, as tags too.
- (tag:1.3) makes a tag stronger. Anima needs higher ones, like (chibi:2),
  and wants an @ before an artist: @name.

## Limits and rights

Don't use an artist tag to imitate a living artist's distinctive style.
Describe what carries over instead: medium, line quality, palette,
lighting, composition, rendering. Tag frequency is not visual importance,
and no tag list proves what a particular model knows. The full guide, with
licensing notes, is guide.md; where the tags come from is sources.md.
''',
  );

  static const adhdSupport = BuiltInSkill(
    id: 'adhd-support',
    title: 'ADHD support',
    on: false,
    always: true,
    description:
        'A way of helping that suits ADHD brains: small next steps, '
        'gentle check-ins, no shame. Always on while switched on.',
    body: '''
Your human finds a way of helping that suits ADHD useful. Keep doing what
you always do, and also:

- **One thing at a time.** When something feels big, find the tiny first
  step (open the document, put on shoes) and offer just that one.
- **Short and clear.** Short paragraphs, lists for steps, the important
  part first. No walls of text.
- **Make time visible.** Give rough times ("about 10 minutes"). Offer a
  set_reminder to come back to a task, take a break, eat or drink water.
- **Body doubling.** Offer to "stay with them" while they do something:
  they tell you when they start and when they finish, and you cheer.
- **Gentle check-ins.** If they planned something with you, ask how it went
  later, kindly. Never guilt-trip about what didn't happen; start again
  from now.
- **Catch the wander.** If they drift off a task they asked for help with,
  note it lightly and offer to park the new idea for later (remember it).
- **Celebrate finishing**, even small things.
- They are the expert on their brain. If something doesn't help, drop it,
  and learn_lesson so you remember.
''',
  );
}

/// A starter skill as VoxCordis brings it.
class BuiltInSkill {
  const BuiltInSkill({
    required this.id,
    required this.title,
    required this.description,
    required this.body,
    this.on = true,
    this.always = false,
    this.files = const {},
    this.older = const [],
  });

  final String id;
  final String title;
  final String description;
  final String body;

  /// Whether it starts switched on.
  final bool on;
  final bool always;

  /// Files that come with it besides SKILL.md, by path in its folder.
  final Map<String, String> files;

  /// Earlier versions of its SKILL.md. A companion that still has one of
  /// them, untouched, gets this version and its files on the next load.
  final List<String> older;

  /// Whether [text] is an earlier version of this skill's SKILL.md.
  bool isOlder(String text) {
    String norm(String v) => v.replaceAll('\r\n', '\n').trim();
    final t = norm(text);
    return older.any((o) => norm(o) == t);
  }

  String toMarkdown() => Skills.markdown(
    id: id,
    title: title,
    description: description,
    always: always,
    body: body,
  );
}

/// The first booru-tags SKILL.md, before it came with tag files.
const _booruTagsV1 = '''
---
name: booru-tags
title: "Booru tags"
description: "Write prompts as Danbooru-style tags for anime picture models (Anima, Animagine, Illustrious, Pony), before draw_picture."
---

# Booru tags

Anime models learned from Danbooru, so they understand its tags far better
than sentences. Build the prompt from tags, comma-separated:

1. **Who and how many:** 1girl, 1boy, 2girls, 1other, solo, multiple girls.
2. **Character and series**, if it is a known one: hatsune miku, vocaloid.
   Brackets in a name are escaped: `hoshimachi suisei \\(1st costume\\)`.
3. **Rating:** safe, sensitive, nsfw or explicit. Pick what your human
   asked for; when unsure, safe.
4. **Looks:** hair (long hair, silver hair, twintails, ahoge), eyes (blue
   eyes, heterochromia), body, expression (smile, blush, closed eyes,
   open mouth). For yourself, take them from the looks in personality.md.
5. **Clothes:** one tag each: white dress, black thighhighs, hoodie.
6. **Pose and framing:** standing, sitting, looking at viewer, from side,
   upper body, full body, close-up, cowboy shot.
7. **Place and light:** outdoors, bedroom, night, cherry blossoms, rain,
   sunset, backlighting.
8. **Style or artist**, if wanted. Anima wants an @ before an artist:
   @name.

Rules:
- Lowercase, spaces instead of underscores (score_7 style tags are the only
  ones with underscores).
- 15 to 40 tags is plenty. Don't repeat a tag; don't write sentences in
  between unless the model takes both (Anima does).
- Quality tags (masterpiece, best quality…) are added by VoxCordis; leave
  them out.
- What to avoid goes in negative_prompt as tags too: extra fingers, text,
  watermark.
- Weights: (tag:1.3) makes a tag stronger. Anima needs higher ones, like
  (chibi:2).
''';
