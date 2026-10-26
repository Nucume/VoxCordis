// Generated from a Danbooru tag archive (wiki tag groups, pulled 2026-10-01):
// one file per tag group, so the companion reads only the ones it needs.

/// The tag files of the booru-tags skill, by path in its folder.
const booruTagFiles = <String, String>{
  'guide.md': r'''
# Danbooru-informed anime prompting

Danbooru is a human-maintained vocabulary and reference-search system, not a universal prompt language. Its current tags can help identify compact, visually grounded concepts, especially for anime checkpoints trained on Danbooru-like captions, but tag behavior depends on the target model, tokenizer, caption pipeline, dataset snapshot, and training date.

## Core categories

- **artist**: creator of an individual image, not the franchise owner.
- **character**: named fictional character.
- **copyright**: source work/franchise.
- **general**: visible concepts: clothes, pose, composition, setting, color, visual attributes.
- **meta**: database/post information, not scene content.

Search prefixes such as `artist:`, `character:`, `copyright:`, `general:`, and `meta:` are chiefly search disambiguators, not automatic generation controls. Danbooru commonly uses underscore-separated canonical names.

## Aliases and implications

An alias maps alternate spellings or old names to a canonical tag. An implication expresses a subset relation: a narrow tag implies a broader tag. They are not synonyms, and a database implication is not a neural-network guarantee. Character tags do not automatically imply their franchise/copyright tags. Prefer current canonical forms, but test variants when a checkpoint may reflect an older dataset.

## Practical anime-checkpoint workflow

1. Read the target model's own prompting guidance first.
2. Start with a small set of unambiguous visual tags, e.g. `solo`, `long_hair`, `blue_eyes`, `school_uniform`, `standing`, `outdoors`.
3. Add composition/camera tags only as needed: `upper_body`, `full_body`, `from_above`, `looking_at_viewer`, `symmetrical_composition`.
4. Verify meaning through the tag wiki and multiple clean examples.
5. Keep character, copyright, artist, and style references separate so their effects can be tested independently.
6. Use negative tags conservatively; an unknown or unlearned negative token may do nothing.
7. Compare tag-oriented and natural-language prompts on the actual checkpoint. Never assume Danbooru syntax transfers equally to SD 1.5, SDXL, Flux, ZiT, or Soulkyn models.

## Limits and rights

Danbooru cannot reveal which tokens a particular model recognizes, their effective weights, tokenizer behavior, or training inclusion. Tag frequency is not visual importance; tags can be absent, inconsistent, inherited, revised, or applied to subtle features. The site is not an art-history authority, style taxonomy, or proof that any artist's style can be reproduced legally or technically.

An image on Danbooru is not automatically public domain, Creative Commons, or licensed for training/reproduction. For commercial or training work, record artist, source URL, copyright/franchise, license, and restrictions; prefer permission-cleared material. Do not use an artist tag as a shortcut to imitate a living artist's distinctive style. Describe transferable properties instead: medium, line quality, palette, lighting, composition, and rendering technique.
''',
  'tags/breasts.md': r'''
# Breasts

### Sizes (in order)
flat chest → small breasts → medium breasts → large breasts → huge breasts → gigantic breasts

Use `large` or `huge` for most prompts. `gigantic` is extreme. "Very large bust" is NOT a Danbooru tag — the model doesn't know it.

### Descriptions
asymmetrical breasts, bouncing breasts, breasts apart, floating breasts, hanging breasts, perky breasts, sagging breasts, unaligned breasts, veiny breasts, pointy breasts

### Visibility
areolae, areola slip, dark areolae, large areolae, light areolae, speckled areolae, backboob, bursting breasts, cleavage, nipples, dark nipples, covered nipples, gaping nipples, huge nipples, nipple indents, inverted nipples, long nipples, nipple slip, no nipples, puffy nipples, small nipples, nipple hair, sideboob, underboob

Whole breasts visible: breast slip, breastless clothes, breasts out, impossible shirt, one breast out

### Clothes for breasts
bandeau, bikini, cupless bikini, bra, cupless bra, no bra, nursing bra, shelf bra, belt bra, breastless clothes, breast curtain, bustier, center opening, chest binder, Cinderella bust, cleavage cutout, corset, framed breasts, nipple cutout, nippleless clothes, plunging neckline, rei no himo, sarashi, taut shirt, underbust

### Breast interactions
penis on breasts, paizuri, autopaizuri, cooperative paizuri, handsfree paizuri, naizuri, reverse paizuri, straddling paizuri, breast smother, breast pillow, head between breasts, face between breasts, breast biting, breastfeeding, breast sucking, licking nipple, breast hold, groping, breast lift, breast press, breasts squeezed together, nipple tweak, cum on breasts, lactation
''',
  'tags/lighting.md': r'''
# Lighting

### Directional
backlighting, overlighting, sidelighting, underlighting

### Types
bloom, spotlight, light rays (sunbeam), light rays (moonbeam), light rays (underwater), dim lighting, sunlight, moonlight

### Light through gaps
crack of light, dappled sunlight, dappled moonlight, window shadow

### Light through objects
caustics, caustics (water), caustics (underwater), dispersion (optics), refraction, subsurface scattering

### Time of day
morning, dawn, twilight, sunrise, day, evening, sunset, dusk, night

### Light sources
stage lights, sun, moon, glowstick, lamp, desk lamp, lamppost, wall lamp, torch, fire, embers, flashlight, lantern, oil lamp, wooden lantern, ceiling light, chandelier, candlelight

### Misc
muzzle flash, headlight, floodlights, flare, ultraviolet light, glowing headgear

### Absence of light
shade, tree shade, shadow, colored shadow, window shadow, dark, darkness
''',
  'tags/image-composition.md': r'''
# Image Composition

### View angle
Dutch angle, from above, from behind, from below, from side, high up, multiple views, sideways, three-quarter view, straight-on, upside-down

### Perspective
atmospheric perspective, fisheye, panorama, perspective, vanishing point

### Framing the body (in order of increasing view, from face)
portrait (face through shoulders) → upper body (face through torso) → cowboy shot (face through thighs) → feet out of frame (face to below knee) → full body → wide shot → very wide shot

From legs: lower body (torso down), head out of frame (neck down), eyes out of frame (nose down)

Other framing: close-up, cropped (legs/torso/arms/shoulders/head), cut-in, profile, group profile, split crop

### Focus tags
solo focus, male focus, breast focus, ass focus, thigh focus, navel focus, armpit focus, back focus, eye focus, foot focus, hand focus, hip focus, pectoral focus, penis focus, plant focus, animal focus, object focus, vehicle focus, weapon focus, text focus

### Styles
abstract, art deco, art nouveau, fake photograph, fine art parody, impressionism, ligne claire, minimalism, nihonga, sumi-e, ukiyo-e, painterly, realistic, photorealistic, sketch, surreal, traditional media, faux traditional media

### Techniques
blending, bloom, bokeh, caustics, chiaroscuro, chromatic aberration, depth of field, distortion, double exposure, drop shadow, emphasis lines, film grain, foreshortening, gradient, halftone, hatching, crosshatching, high contrast, lens flare, motion blur, motion lines, negative space, overexposure, pointillism, scanlines, screentones, silhouette, speed lines, stippling, subsurface scattering, vignetting
''',
  'tags/face.md': r'''
# Face Tags

### Emotions
angry, anger vein, annoyed, clenched teeth, glaring, scowl, blush, blush stickers, embarrassed, full-face blush, nose blush, bored, closed eyes, confused, crazy, despair, determined, disappointed, disdain, disgust, drunk, envy, excited, exhausted, expressionless, facepalm, flustered, frustrated, furrowed brow, grimace, guilt, happy, lonely, nervous, nosebleed, pain, pout, raised eyebrow, sad, depressed, frown, tears, scared, panicking, worried, serious, shaded face, shy, sigh, skeptical, sleepy, sulking, surprised, thinking, pensive, unamused, wince, struggling

### Sexual expressions
afterglow, ahegao, aroused, fucked silly, in heat, naughty face, seductive smile, torogao

### Smiles
:D (open-mouthed smile), crazy smile, evil smile, fingersmile, forced smile, grin, evil grin, light smile, sad smile, seductive smile, smile (mouth closed), stifled laugh, doyagao (smug), smirk, smug

### Gazes
looking afar, looking around, looking at another, eye contact, looking at breasts, looking at crotch, looking at hand, looking at mirror, looking at object, looking at penis, looking at phone, looking at pussy, looking at self, looking at viewer, looking back, looking down, looking outside, looking over eyewear, looking to the side, looking up

### Eye states
half-closed eyes, narrowed eyes, wide-eyed, sparkling eyes, closed eyes, blinking, one eye closed (winking), pleading eyes, squinting, staring, empty eyes, heart-shaped eyes

### Emotes
:D, ;D, XD, D:, :3, ;3, x3, 0w0, uwu, :p, ;p, >:), >:(, :T, :/, :|, x mouth, :c, c:, :<, ;<, :>, :o, ;o, o3o, >3<, o_o, 0_0, ^_^, >_<, @_, >_@, +_+, =_=, T_T

### Mouth shapes
open mouth, parted lips, round mouth, heart-shaped mouth, hollow mouth, mouth drool, no mouth, peanut mouth, triangle mouth, wavy mouth, diamond mouth, dot mouth, chestnut mouth

### Eyebrows
furrowed brow, raised eyebrow, raised eyebrows, raised inner eyebrows, v-shaped eyebrows, eyebrows hidden by hair, mismatched eyebrows
''',
  'tags/eyes.md': r'''
# Eyes Tags

### Iris colors
aqua eyes, black eyes, blue eyes, brown eyes, green eyes, grey eyes, orange eyes, purple eyes, pink eyes, red eyes, white eyes, yellow eyes

### Multi-color
heterochromia, multicolored eyes, gradient eyes, two-tone eyes, rainbow eyes

### Pupil shapes
constricted pupils, dilated pupils, slit pupils, heart-shaped pupils, star-shaped pupils, diamond-shaped pupils, flower-shaped pupils, cross-shaped pupils, x-shaped pupils, solid circle pupils, mismatched pupils

### Sclera
blue sclera, black sclera, blank eyes (white sclera), bloodshot eyes, red sclera, yellow sclera, no sclera

### Around eyes
bags under eyes, aegyo sal, glowing eyes, glowing eye

### Eye shapes
tareme (drooping), tsurime (upward point), sanpaku, big eyes, narrowed eyes, upturned eyes
''',
  'tags/hair-styles.md': r'''
# Hair Styles

### Length
very short hair (above jaw) → short hair (above shoulders) → medium hair (shoulder length) → long hair (shoulders to waist) → very long hair (waist to feet) → absurdly long hair (past feet)

big hair (voluminous), bald, balding

### Styles by length
Very short: buzz cut, crew cut, pixie cut
Short: bob cut, inverted bob, bowl cut, undercut, flattop, short hair with long locks
Medium: wolf cut
Long: hime cut, jellyfish cut, mullet

### Braids
braided bangs, front braid, side braid, crown braid, single braid, multiple braids, twin braids, low twin braids, tri braids, quad braids, rope braid, cornrows, dreadlocks, box braids, half up braid

### Buns
single hair bun, double bun, cone hair bun, donut hair bun, heart hair bun, triple bun

### Ponytails
half updo, one side up, two side up, high ponytail, low ponytail, side ponytail, split ponytail, topknot, twintails, low twintails, short twintails, uneven twintails, tri tails, quad tails, quin tails

### Texture
curly hair, flipped hair, drill hair, twin drills, messy hair, pointy hair, ringlets, spiked hair, straight hair, wavy hair, fluffy hair

### Bangs
arched bangs, asymmetrical bangs, blunt bangs, wispy bangs, choppy bangs, diagonal bangs, short bangs, long bangs, hair between eyes, hair over one eye, hair over eyes, parted bangs, double-parted bangs, swept bangs, colored bangs, sidelocks, asymmetrical sidelocks, widow's peak

### Top of head
ahoge, heart ahoge, huge ahoge, antenna hair, hair pulled back, hair slicked back, parted hair, mohawk
''',
  'tags/nudity.md': r'''
# Nudity

### Complete
completely nude, nude

### By gender
CFNF, CFNM, CMNF, CMNM

### Partial nudity
clothing aside, clothes down, open clothes, revealing clothes, see-through clothes, unbuttoned, undressing, unzipped

### Exposed shoulders/arms
armpits, bare arms, bare shoulders, off shoulder, sleeveless

### Exposed chest
center opening, open collar, shirt no, shirt open, topless male, topless female

### Exposed breasts
breastless clothes, one breast out, breast slip, breasts out, bra no, bra lift, bra pull

### Parts of breasts
backboob, cleavage, cleavage cutout, sideboob, underboob, underboob cutout

### Nipples
areola slip, nipple slip, nipples (visible)

### Torso
backless outfit, bare back, midriff, navel cutout, side cutout, stomach cutout

### Legs/feet
barefoot, bare legs, thigh cutout, side slit, zettai ryouiki

### Ass/crotch
bottomless, ass cutout, crotch cutout, panties no, panties aside, pants pull, skirt pull, skirt lift, pussy peek, penis peek

### Naked + specific item
naked apron, naked cape, naked coat, naked hoodie, naked jacket, naked ribbon, naked robe, naked scarf, naked sheet, naked shirt, naked towel, underwear only

### POV
downblouse, pantyshot, upskirt
''',
  'tags/sexual-positions.md': r'''
# Sexual Positions

### Main
69, sex from behind, doggystyle, bent over, prone bone, standing sex, top-down bottom-up, spitroast, reverse spitroast, spooning, on side

### On top
girl on top, amazon position, cowgirl position, squatting cowgirl position, reverse cowgirl position, reverse upright straddle, upright straddle

### On bottom
boy on top, anvil position, missionary, mating press, suspended congress, reverse suspended congress, full nelson, piledriver, mounting, standing missionary

### Folded
folded / knees to chest / legs over head / legs up

### Bondage-specific
bound arms, bound wrists, bound legs, bound breasts, box tie, reverse prayer, frogtie, hogtie, separated arms, separated legs, shrimp tie, strappado, suspension, cuffs-to-collar
''',
  'tags/sex-acts.md': r'''
# Sex Acts

### Stimulation
footjob, double footjob, frottage (dry humping), armpit sex, pussyjob, buttjob, paizuri, autopaizuri, naizuri, thigh sex, glansjob, groping, handjob, double handjob, cooperative handjob, nursing handjob, reach-around, two-handed handjob, masturbation, female masturbation, male masturbation, mutual masturbation

### Oral
anilingus, rusty trombone, cunnilingus, autocunnilingus, fellatio, autofellatio, deepthroat, irrumatio, cum swap, licking testicle, sitting on face (facesitting), testicle sucking

### Group sex
group sex, bisexual, gangbang, double penetration, triple penetration, orgy, spitroast, threesome (MMF, FFM, etc.), foursome, fivesome

### Penetration
vaginal, double vaginal, anal, double anal, pegging, cervical penetration, deep penetration, fisting, anal fisting, fingering, anal fingering, prostate milking

### Same-sex
yaoi (male-male), bara, yuri (female-female), tribadism (scissoring)

### After sex
after sex, afterglow, clothed after sex, after vaginal, after anal, after fellatio

### Cum
cum, bukkake, facial, cum on breasts, cum on ass, cum on body, cum on face, cum in mouth, cum in pussy, cum in ass, ejaculation, pull out, creampie

### Fetish categories
bdsm, bondage, shibari, femdom, dominatrix, humiliation, masochism, sadism, slave, spanking, exhibitionism, public use, voyeurism, cheating, netorare, tentacles, pregnant, defloration, lactation, human furniture, crossdressing, trap, futanari
''',
  'tags/attire.md': r'''
# Attire

### Headwear
hat, headband, headdress, maid headdress, crown, diadem, tiara, veil, hair bow, hair ribbon, hair tie, hairband

### Shirts/tops
blouse, frilled shirt, sleeveless shirt, bustier, crop top, camisole, cardigan, coat, duffel coat, fur coat, long coat, overcoat, peacoat, raincoat, trench coat, winter coat, corset, dress, halterneck, hoodie, jacket, blazer, cropped jacket, letterman jacket, nightgown, poncho, robe, shirt, collared shirt, dress shirt, off-shoulder shirt, t-shirt, sweater, turtleneck sweater, sleeveless turtleneck, tank top, tube top, bandeau, underbust, vest, waistcoat

### Bottoms
bloomers, buruma, chaps, kilt, pants, bell-bottoms, capri pants, jeans, cutoff jeans, yoga pants, shorts, bike shorts, denim shorts, gym shorts, micro shorts, short shorts, skirt, miniskirt, microskirt, pleated skirt, plaid skirt, high-waist skirt, long skirt, tutu

### Legwear
kneehighs, leggings, leg warmers, over-kneehighs, pantyhose, thighband pantyhose, socks, ankle socks, thighhighs

### Footwear
boots, ankle boots, armored boots, cowboy boots, high heel boots, knee boots, thigh boots, sneakers, dress shoes, loafers, oxfords, flats, high heels, pumps, stiletto heels, mary janes, platform shoes, sandals, geta, slippers

### Uniforms/costumes
apron, armor, cape, cassock, cheerleader, formal clothes, suit, business suit, tuxedo, gym uniform, harem outfit, kimono, maid, miko, military uniform, nun, pajamas, priest, sailor uniform, school uniform, serafuku, santa costume, swimsuit, competition swimsuit, slingshot swimsuit, school swimsuit, bikini, string bikini, micro bikini, playboy bunny, bodysuit, leotard

### Traditional
chinese clothes, china dress (cheongsam/qipao), hanfu, japanese clothes, hakama, kimono, furisode, yukata, haori, sarashi, korean clothes, hanbok, ao dai

### Jewelry/accessories
earrings, hoop earrings, stud earrings, hairclip, hairpin, hair stick, kanzashi, choker, collar, necklace, necktie, bowtie, scarf, armlet, bracelet, bangle, gloves, fingerless gloves, elbow gloves, ring, anklet, belt, harness, brooch, lapel pin, badge

### Patterns
argyle, checkered, camouflage, floral print, gingham, houndstooth, plaid, polka dot, striped, animal print, leopard print, star print, starry sky print, moon print, cherry blossom print

### Trims/details
frills, fur trim, gold trim, lace trim, silver trim, white trim, flower trim, ribbon trim, criss-cross straps, clothing cutout, see-through clothes, taut shirt, torn clothes
''',
  'tags/posture.md': r'''
# Posture

### Basic positions
Kneeling, on one knee, lying, crossed legs, fetal position, on back, on side, on stomach, sitting, butterfly sitting, seiza, reclining, wariza, yokozuwari, standing, balancing, legs apart, standing on one leg

### Movement
crawling, midair, falling, floating, flying, jumping, hopping, pouncing, running, walking, walk cycle, walking on wall

### Whole body
all fours, top-down bottom-up, prostration, bear position, bowlegged pose, chest stand, cowering, crucifixion, fighting stance, spread eagle position, squatting, stretching, superhero landing, upside-down, handstand, headstand, yoga, scorpion pose

### Torso
arched back, bent back, bent over, leaning back, leaning forward, slouching, sway back, twisted torso

### Arms
arm behind back, arms behind back, arm up, arms up, arms behind head, outstretched arm, outstretched arms, spread arms, arms at sides, airplane arms, crossed arms, flexing, reaching, T-pose, A-pose, V arms, W arms

### Hands
stroking own chin, outstretched hand, interlocked fingers, own hands clasped, own hands together, star hands

### Legs
crossed ankles, folded, leg up, legs up, knees to chest, legs over head, leg lift, outstretched leg, split, standing split, spread legs, watson cross, uneven footing, knees apart feet together, knees together feet apart, knee up, knees up

### Feet
dorsiflexion, pigeon-toed, plantar flexion, toe scrunch, tiptoes, tiptoe kiss

### Two characters
ass-to-ass, back-to-back, belly-to-belly, cheek-to-breast, cheek-to-cheek, eye contact, face-to-face, forehead-to-forehead, head on chest, heads together, holding hands, leg lock, locked arms, over the knee, nipple-to-nipple, noses touching, shoulder-to-shoulder, tail lock

### Carrying
baby carry, carrying, carried breast rest, carrying over shoulder, carrying under arm, fireman's carry, piggyback, princess carry, shoulder carry, sitting on shoulder, standing on shoulder

### Poses
archer pose, bras d'honneur, body bridge, contrapposto, dojikko pose, ghost pose, letter pose, ojou-sama pose, saboten pose, villain pose, zombie pose, gendou pose, henshin pose, jojo pose

### Signature poses
Charizard pose, Gendou pose, Henshin pose, JoJo pose, Dio Brando's pose, Giorno Giovanna's pose, Jonathan Joestar's pose, Kujo Jotaro's pose, Kongou pose, Kujou Karen pose, Z-Move trainer pose
''',
  'tags/ass.md': r'''
# Ass

### Anatomy
ass, ass expansion, bad ass, flat ass, huge ass, gigantic ass, spread ass, butt crack, underbutt, wedgie

### Anus
anal hair, anus, no anus, puckered anus, spread anus, tiny anus

### Ass and hands
anal fingering, anal fisting, ass smack, covering anus, covering ass, grabbing another's ass, grabbing own ass, groping, hand on another's ass, hand on own ass, hands on another's ass, hands on own ass

### Ass and heads
biting ass, smelling ass, head on ass

### Ass with cum
cum in ass, cum on ass

### Misc
anal, anal hook, ass-to-ass, ass cutout, ass on glass, ass ache, ass focus, ass shake, ass visible through thighs, bouncing ass
''',
  'tags/skin-color.md': r'''
# Skin Color

### Natural
dark skin, dark-skinned female, dark-skinned male, very dark skin, pale skin, tan, tanlines, tan tattoo

### Unnatural
aqua skin, black skin, blue skin, green skin, grey skin, orange skin, pink skin, purple skin, red skin, silver skin, white skin, yellow skin

### Alternate materials
ghost hands, metal skin, plastic skin, shadow hands

### Quantity
multicolored skin, two-tone skin, patchwork skin, vitiligo

### Related
colored skin, colored extremities, shiny skin, body blush
''',
  'tags/dress.md': r'''
# Dress

### Colors
aqua dress, black dress, blue dress, brown dress, green dress, grey dress, orange dress, pink dress, purple dress, red dress, white dress, yellow dress, multicolored dress, two-tone dress, two-sided dress

### Patterns
argyle dress, checkered dress, flag dress, plaid dress, polka dot dress, print dress, striped dress, vertical-striped dress, pinstripe dress

### Length
long dress, medium dress, short dress, microdress

### Details
armored dress, backless dress, collared dress, frilled dress, fur-trimmed dress, glitter dress, halter dress, highleg dress, high-low skirt, impossible dress, lace-trimmed dress, latex dress, layered dress, off-shoulder dress, pleated dress, plunging neckline, ribbed dress, ribbon-trimmed dress, side slit, taut dress, see-through dress, sleeveless dress, strapless dress

### Models
cake dress, china dress, coat dress, cocktail dress, denim dress, dirndl, evening gown, flowing dress, funeral dress, gown, mermaid dress, negligee, nightgown, pencil dress, pinafore dress, sailor dress, santa dress, sundress, sweater dress, tennis dress, tent dress, trapeze dress, tube dress, ao dai, wedding dress

### Actions
dress flip, dress grab, dress lift, dress pull, dress tug, open dress, tied dress, torn dress, wet dress
''',
  'tags/legwear.md': r'''
# Legwear

### By height
socks, kneehighs, over-kneehighs, thighhighs, hiphighs, pantyhose, leggings, detached leggings

### Colors
gradient legwear, multicolored legwear, multicolored leggings, multicolored pantyhose, multicolored socks, multicolored thighhighs, two-tone legwear

### Patterns
american flag legwear, camouflage legwear, checkered legwear, diagonal-striped legwear, gingham legwear, polka dot legwear, polka dot leggings, polka dot pantyhose, polka dot socks, polka dot thighhighs, rainbow legwear

### Bands
animal ear legwear, bat legwear, bear band legwear, rabbit ear legwear, cat ear legwear, horn band legwear

### Style
aran legwear, armored legwear, bow legwear, cross-laced legwear, fishnet legwear, fishnet leggings, fishnet pantyhose, fishnet socks, fishnet thighhighs, fluffy legwear, knit legwear, lace legwear, lace pantyhose, lace socks, lace thighhighs, lace-up legwear, lace-trimmed legwear, latex legwear, ribbed legwear, seamed legwear, back-seamed legwear, front-seamed legwear, side-seamed legwear, see-through legwear, shiny legwear, side-tie legwear, spiked legwear, studded legwear, toeless legwear, bridal legwear, stirrup legwear, zipper legwear, fur-trimmed legwear, ribbon-trimmed legwear, legwear bell, o-ring legwear

### Actions
adjusting legwear, holding legwear, pulling off legwear, putting on legwear, removing legwear

### Misc
alternate legwear, uneven legwear, dirty legwear, in legwear, layered legwear, unworn legwear, mismatched legwear, missing legwear, torn legwear, torn leggings, torn leg warmers, torn pantyhose, torn socks, torn thighhighs
''',
  'tags/hands.md': r'''
# Hands

### Hand on Self — Shoulders and up
adjusting_eyewear, hand_on_own_ear, hand_on_own_head, hand_on_own_face, hand_on_own_forehead, hand_on_own_cheek, hand_on_own_chin, head_rest, hand_on_headwear

### Hands on Self — upper body (except breasts)
hand_on_own_neck, hand_on_own_chest, hand_on_own_shoulder, hand_on_own_stomach, hand_on_own_arm, hand_on_own_elbow

### Hands on breasts
breast_hold_oneself_only, grabbing_own_breast_grabbing_another_breast, flat_chest_grab, guided_breast_grab, breast_lift, breasts_squeezed_together, breast_suppress, groping, arm_between_breasts, hand_in_bra, nipple_tweak, poking_another_breast_poking_own_breast

### Hands on lower body
hand_on_another_waist_hands_on_another_waist, hand_on_own_crotch_hand_on_another_crotch_hands_on_own_crotch_hands_on_another_crotch, hand_on_own_ass_hand_on_another_ass, hand_on_own_hip_hand_on_another_hip_hands_on_own_hips_hands_on_another_hips, hand_on_own_leg_hand_on_another_leg_hands_on_own_legs_hands_on_another_leg, hand_on_own_thigh_hand_on_another_thigh_hands_on_own_thighs_hands_on_another_thighs, hand_on_own_knee_hand_on_another_knee_hands_on_own_knees_hands_on_another_knees, hand_between_legs

### Hands on members
hand_on_own_foot_hand_on_another_foot_hands_on_own_feet_hands_on_feet, holding_hands_hand_on_another_hand

### Hands somewhere else
hand_in_pocket_hands_in_pockets

### Hand on another person — Shoulders and up
adjusting_another_hair, hand_on_another_ear, hand_on_another_head, headpat, hand_on_another_face, hand_on_another_cheek, cheek_pinch, cheek_poking, cheek_squash, hand_on_another_chin, hand_on_another_neck, strangling

### Hand on another person — Below Shoulders
arm_around_shoulder, hand_on_another_arm, hand_on_another_back, patting_back, hand_on_another_chest, hand_on_another_shoulder, hand_on_another_stomach

### Strange Hands
hand_eye, hand_mouth
''',
  'tags/gestures.md': r'''
# Gestures

### Gestures encompassing at least two hands
air_quotes, carry_me, clenched_hands, cupping_hands, double_finger_gun, double_v, fidgeting, finger_counting, finger_frame, fist_bump, fist_in_hand, groping_motion, hand_glasses, heart_arms, heart_hands, heart_hands_duo, heart_hands_trio, heart_hands_quartet, high_five, horns_pose, kitsune_no_mado, noogie, own_hands_clasped, palm_fist_greeting, palm_fist_tap, penetration_gesture, pinky_swear, rabbit_pose, shadow_puppet, steepled_fingers, tsuki_ni_kawatte_oshioki_yo, x_arms, x_fingers

### Gestures — One open finger
akanbe, beckoning, twirling_hair, index_finger_raised, middle_finger, pinky_out, pointing, pointing_at_another, pointing_at_self, pointing_at_viewer, pointing_spiderman, pointing_down, pointing_forward, pointing_up, kamina_pose, saturday_night_fever, shushing, slit_throat, thumbs_down, thumbs_up

### Gestures — Two open fingers
crossed_fingers, finger_gun, finger_heart, fox_shadow_puppet, gyaru_v, inward_v, shaka_sign, two_finger_salute, v, v_over_eye, v_over_mouth

### Gestures — Three open fingers
middle_w, money_gesture, ok_sign, w

### Gestures — Whole open hand
claw_pose, facepalm, ohikaenasutte, open_hand, reaching, salute, spread_fingers, stop, straight_arm_salute, vulcan_salute, waving

### Gestures — Whole closed hand
clenched_hand, curled_fingers, dojikko_pose, fig_sign, paw_pose, power_fist, raised_fist, che_vuoi?_(italian_gesture)

### Variable number of open fingers
beckoning, cunnilingus_gesture, fellatio_gesture, handjob_gesture, hat_tip, oral_invitation, oral_simulation, shocker, stroking_own_chin

### Other gestures
air_guitar, bowing, curtsey, distress_hand_signal, heart_tail, heart_tail_duo, kuji_in, orchid_fingers, shrugging, toe_point, victory_pose
''',
  'tags/headwear.md': r'''
# Headwear

### Types
crown, hat, helmet

### Colours
aqua_hat, black_hat, blue_hat, brown_hat, green_hat, grey_hat, orange_hat, pink_hat, purple_hat, red_hat, white_hat, yellow_hat

### Hats — With visor
baseball_cap, budenovka, deerstalker, dianzi, field_cap, kepi, m43_field_cap, mao_cap, newsboy_cap, peaked_cap, rogatywka, shako_cap, mini_shako_cap

### Hats — With brim
bicorne, boater_hat, boonie_hat, bowler_hat, bucket_hat, campaign_hat, cavalier_hat, cloche_hat, cowboy_hat, straw_hat, ajirogasa, amigasa, ayaigasa, ichimegasa, ronin_gasa, sandogasa, torioi_gasa, rice_hat, fascinator, fedora, female_service_cap, flat_cap, gat, paeraengi, jingasa, mob_cap, picture_hat, pirate_hat, pith_helmet, porkpie_hat, shampoo_hat, sombrero, sun_hat, top_hat, mini_top_hat, tricorne, trilby, tulip_hat, witch_hat, mini_witch_hat, wizard_hat

### Hats — With ear flaps
deerstalker, earflap_beanie, budenovka, papakha, ushanka

### Hats — Brimless
ayam_hat, bashlik, beanie, earflap_beanie, beret, chef_hat, flat_top_chef_hat, toque_blanche, coif, dixie_cup_hat, donald_duck_sailor_hat, dunce_cap, fez_hat, flight_attendant_hat, fur_hat, bearskin_cap, papakha, ushanka, garrison_cap, hennin, kippah, mian_guan, mitre, mortarboard, nightcap, nurse_cap, party_hat, pillbox_hat, qingdai_guanmao, guapi_mao, sailor_hat, sajkaca, santa_hat, mini_santa_hat, songkok, tam_o'_shanter, tate_eboshi, tengai, tokin_hat, tsunokakushi, xiezhi_guan

### Misc
animal_hat, hat_with_ears, deviruchi_hat, bear_hat, rabbit_hat, cat_hat, dog_hat, fox_hat, pelt, penguin_hat, wolf_hat, eggshell_hat, pumpkin_hat

### Helmets
adrian_helmet, altyn_helmet, american_football_helmet, animal_ear_helmet, baseball_helmet, bicycle_helmet, brodie_helmet, diving_helmet, dragoon_helmet, fishbowl_helmet, hard_hat, headlamp, helm, horned_helmet, kabuto, kettle_helm, m1_helmet, motorcycle_helmet, pickelhaube, pilot_helmet, pith_helmet, sallet, space_helmet, stahlhelm, tank_helmet, winged_helmet

### Crowns
circlet, diadem, fengguan, mian_guan, mini_crown, saishi, tiara

### Other
aviator_cap, balaclava, bandana, bonnet, dalachi, futou, headscarf, hijab, jester_cap, jin, dongpo_jin, tang_jin, zhouzi_jin, keffiyeh, object_on_head, bowl_hat, bloomers_on_head, book_on_head, bra_on_head, bucket_on_head, food_on_head, panties_on_head, traffic_cone_on_head, okosozukin, shower_cap, shufa_guan, tenugui, turban, visor_cap, veil, zhuang_hat

### Non-specific styles
camouflage_headwear, checkered_headwear, frilled_hat, military_hat, mini_hat, multicolored_headwear, police_hat, print_headwear, school_hat, straw_hat

### Actions / states
adjusting_headwear, backwards_hat, sideways_hat, hand_on_headwear, hands_on_headwear, hat_basket, hat_loss, hat_on_chest, hat_over_eyes, hat_over_one_eye, hat_tip, holding_unworn_hat, holding_unworn_helmet, missing_headwear, putting_on_headwear, removing_helmet, tilted_headwear, torn_hat, unworn_hat, unworn_headwear, unworn_helmet

### Accessories
chinstrap, hat_bow, hat_feather, hat_flower, hat_ornament, anchor_hat_ornament, butterfly_hat_ornament, character_hat_ornament, crescent_hat_ornament, dolphin_hat_ornament, food_themed_hat_ornament, fruit_hat_ornament, grape_hat_ornament, peach_hat_ornament, pumpkin_hat_ornament, gear_hat_ornament, heart_hat_ornament, holly_hat_ornament, jack_o'_lantern_hat_ornament, leaf_hat_ornament, palette_hat_ornament, star_hat_ornament, skull_hat_ornament, hat_tassel, hat_ribbon, hat_with_ears, lappet

### Not headwear
hair_bow, hair_ribbon, hairband, headband, forehead_protector, hachimaki, nejiri_hachimaki, mongkhon, sweatband, headdress, maid_headdress, native_american_headdress, warbonnet, veil
''',
  'tags/eyewear.md': r'''
# Eyewear

### Main
glasses, goggles, monocle, sunglasses

### Eyewear Frame colors
aqua-framed eyewear, black-framed eyewear, blue-framed eyewear, brown-framed eyewear, green-framed eyewear, grey-framed eyewear, orange-framed eyewear, pink-framed eyewear, purple-framed eyewear, red-framed eyewear, white-framed eyewear, two-tone eyewear, yellow-framed eyewear

### Lens colors
aqua-tinted eyewear, blue-tinted eyewear, brown-tinted eyewear, gradient-tinted eyewear, green-tinted eyewear, grey-tinted eyewear, multicolor-tinted eyewear, rainbow-tinted eyewear, orange-tinted eyewear, pink-tinted eyewear, purple-tinted eyewear, red-tinted eyewear, yellow-tinted eyewear

### Types
animal-themed eyewear, cat eye-framed eyewear, food-themed eyewear, heart-shaped eyewear, rectangular eyewear, rimless eyewear, round eyewear, semi-circular eyewear, semi-rimless eyewear, over-rim eyewear, under-rim eyewear, teardrop-framed glasses, triangular eyewear, tortoiseshell-framed eyewear

### Actions
alternate eyewear, adjusting eyewear, bespectacled, broken eyewear, cleaning eyewear, crooked eyewear, cum on eyewear, eyewear on head, eyewear on headwear, eyewear strap, eyewear switch, eyewear view, fogged glasses, hand on eyewear, looking over eyewear, no eyewear, removing eyewear, unworn eyewear, eyewear hang, eyewear in mouth, holding removed eyewear, looking for glasses

### Accessories
eyewear strap, glasses case, nose pads

### Glasses Types
3D glasses, aviator glasses, coke-bottle glasses, diving mask, novelty glasses, heart-shaped eyewear, star-shaped eyewear, teardrop-framed glasses, aviator goggles, groucho glasses, lorgnette, opaque glasses, opera glasses, pince-nez, safety glasses, scouter, ski goggles, X-ray glasses

### Sunglasses
aviator sunglasses, Kamina shades, shutter shades, Simon shades, pixel sunglasses (pixelated glasses)
''',
  'tags/neck-and-neckwear.md': r'''
# Neck and Neckwear

### Anatomy of the neck
collarbone, nape, neck, long neck

### Actions / Posture
arm around neck / arms around neck, hand on another's neck / hands on another's neck, strangling, hand on own neck / hands on own neck, biting neck, kissing neck

### Detached Neckwear — Chokers and Standalone Collars
choker, animal collar (dog collar), belt collar, frilled collar, fur collar, fur-trimmed collar, heart collar, lace-trimmed collar, metal collar, o-ring choker, o-ring collar, padlocked collar, pendant choker, spiked collar, studded collar, ribbon choker

### Detached Neckwear — Other Standalone
bandana around neck, neck warmer, neck ring, neck ruff, scarf, pet cone

### Shirt and Dress Collar Designs
contrast collar, open collar, detached collar, rounded collar, round collar

### Neck lines
turtleneck, crew neck, v-neck, scoop neck, square neckline, low neckline, plunging neckline

### High
mandarin collar, high collar, mystical high collar, medici collar, popped collar

### Folded and low
wing collar, wingtip collar, bib collar, guimpe, puritan collar, peter pan collar, sailor collar

### Accessories
neck bell (jingle bell), neck ribbon, neck tassel, necklace

### Ties
ascot, bolo tie, bowtie, cross tie, neckerchief, necktie

### On Shoulders
feather boa, stole, usekh collar, capelet, cloak with hood down, shrug (clothing)

### Misc. neckwear
animal around neck, bandana around neck, eyewear around neck, goggles around neck, gorget, headphones around neck, lanyard, mask around neck, towel around neck, whistle around neck

### Collared clothes — Collared
collared blouse, collared cape, collared capelet, collared coat, collared crop top, collared dress, collared leotard, collared shirt, collared shrug, collared vest

### Collared clothes — Halterneck
halter dress, halter leotard, halter shirt, criss-cross halter

### Collared clothes — Sailor collar
sailor bikini, sailor dress, sailor shirt, serafuku

### Collared clothes — Turtleneck
sleeveless turtleneck, turtleneck bodysuit, turtleneck dress, turtleneck jacket, turtleneck one-piece swimsuit, turtleneck shirt

### Neckwear actions — Adjusting
adjusting collar, adjusting neckerchief, adjusting necklace, adjusting neck ribbon, adjusting necktie, adjusting scarf

### Neckwear actions — Grabbing
neckwear grab, collar grab, neckerchief grab, neck ribbon grab, necktie grab, scarf grab

### Neckwear actions — Not wearing
unworn choker, unworn neckerchief, unworn necklace, unworn necktie, unworn scarf, no neckwear, no choker, no necklace, no necktie, no scarf
''',
  'sources.md': r'''
# Sources

- Danbooru tag group index: https://danbooru.donmai.us/wiki_pages/tag_groups
- Tag groups pulled via Wayback Machine (snapshots 2025-11 through 2026-05), 2026-10-01
- Tag groups archived: breasts, lighting, image composition, face, eyes, hair styles, nudity, sexual positions, sex acts, attire, posture, ass, skin color, dress, legwear, hands, gestures, headwear, eyewear, neck and neckwear
- Tag groups not yet pulled: body parts, sexual attire, sex objects, feet, shoulders, tail, wings, colors, backgrounds, focus tags, symbols, text, patterns

Research note: direct Danbooru wiki access was Cloudflare-blocked; Wayback Machine used with varying timestamps to avoid rate-limiting. Archive pulled 2026-10-01, batch 2 pulled 2026-10-01.
''',
};
