# Stable Diffusion prompt: a definitive guide - Stable Diffusion Art

*By Andrew*

Developing a process to build good prompts is the first step every Stable Diffusion user tackles. This article summarizes the process and techniques developed through experimentations and other users’ inputs. The goal is to write down all I know about prompts so you can know them all in one place.

## Anatomy of a good prompt

A good prompt needs to be detailed and specific. A good process is to look through a list of keyword categories and decide whether you want to use any of them. 

The keyword categories are

1. Subject
2. Medium
3. Style
4. Art-sharing website
5. Resolution
6. Additional details
7. Color
8. Lighting

An extensive list of keywords from each category is available in the prompt generator. You can also find a short list [here](https://stable-diffusion-art.com/how-to-come-up-with-good-prompts-for-ai-image-generation/#Some_good_keywords_for_you).

You don’t have to include keywords from all categories. Treat them as a checklist to remind you what could be used. 

Let’s review each category and generate some images by adding keywords. I will use the Dreamshaper model, an excellent model for beginners. 

To see the effect of the prompt alone, I won’t be using negative prompts for now. Don’t worry. We will study negative prompts in the later part of this article. 

All images are generated with 25 steps of DPM++ 2M Karas sampler and an image size of 512×768.

## Subject

**The subject** is what you want to **see** in the image. A common mistake is not writing enough about the subjects.

Let’s say we want to generate a sorceress casting magic. A newbie may write

You get some decent images, but this prompt leaves too much room for imagination. (It is common to see the face garbled in Stable Diffusion. There are [ways](https://stable-diffusion-art.com/common-problems-in-ai-images-and-how-to-fix-them/) to fix it.)

How do you want the sorceress to look? Do you have any keywords to describe her more specifically? What does she wear? What kind of magic is she casting? Is she standing, running, or floating in the air? What’s the background scene?

Stable Diffusion cannot read our minds. We have to say exactly what we want.

As a demo, let’s say she is powerful and mysterious and uses lightning magic. She wears a leather outfit with gemstones. She sits down on a rock. She wears a hat. The background is a castle.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background

Now, we generate more specific images. The outfit, the pose and the background are consistent across images.

## Medium

Medium is the material used to make artwork. Some examples are illustration, oil painting, 3D rendering, and photography. Medium has a strong effect because one keyword alone can dramatically change the style.

Let’s add the keyword **digital art**.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art 

The images switched from a realistic painting style to being more like computer graphics. I think we can stop here. Just kidding.

## Style

The **style** refers to the artistic style of the image. Examples include impressionist, surrealist, pop art, etc.

Add **hyperrealistic**, **fantasy**, **dark art** to the prompt.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art

Now, the scene has become darker and more gloomy.

## Art-sharing website

Niche graphic websites such as Artstation and Deviant Art aggregate many images of distinct genres. Using them in a prompt is a sure way to steer the image toward these styles.

Let’s add **artstation** to the prompt.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art, artstation

It’s not a huge change, but the images do look like what you would find on Artstation.

## Resolution

Resolution represents how sharp and detailed the image is. Let’s add keywords **highly detailed** and **sharp focus**.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art, artstation, highly detailed, sharp focus

Well, it’s not a huge effect, perhaps because the previous images are already pretty sharp and detailed. But it doesn’t hurt to add.

## Additional details

Additional details are sweeteners added to modify an image. We will add **sci-fi** and **dystopian** to add some vibe to the image.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art, artstation, highly detailed, sharp focus, sci-fi, dystopian

## Color

You can control the overall color of the image by adding **color keywords**. The colors you specified may appear as a tone or in objects.

Let’s add some golden color to the image with the keyword **iridescent gold**.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art, artstation, highly detailed, sharp focus, sci-fi, dystopian, iridescent gold

The gold comes out great in a few places!

## Lighting

Any photographer would tell you lighting is key to creating successful images. Lighting keywords can have a huge effect on how the image looks. Let’s add studio lighting to make it studio photo-like.

> a beautiful and powerful mysterious sorceress, smile, sitting on a rock, lightning magic, hat, detailed leather clothing with gemstones, dress, castle background, digital art, hyperrealistic, fantasy, dark art, artstation, highly detailed, sharp focus, sci-fi, dystopian, iridescent gold, studio lighting

This completes our example prompt.

You may have noticed the images are already pretty good with only a few keywords added. More is not always better when building a prompt. You often don’t need many keywords to get good images.

## Negative prompt

Using [negative prompts](https://stable-diffusion-art.com/how-to-use-negative-prompts/) is another great way to steer the image, but instead of putting in what you want, you put in what you don’t want. They don’t need to be objects. They can also be styles and unwanted attributes. (e.g., ugly, deformed)

Using negative prompts is a must for [v2 models](https://stable-diffusion-art.com/models/#v2_models). Without it, the images would look far inferior to v1’s. They are optional for v1 and SDXL models, but I routinely use a boilerplate negative prompt because they either help or don’t hurt.

I will use a simple universal negative prompt that doesn’t modify the style. You can [read more](https://stable-diffusion-art.com/how-to-use-negative-prompts/) about it to understand how it works.

> disfigured, deformed, ugly

## Process of building a good prompt

### Iterative prompt building

You should approach prompt building as an iterative process. As the previous section shows, the images could be pretty good with just a few keywords added to the subject.

I always start with a simple prompt with subject, medium, and style only. Generate at least 4 images at a time to see what you get. Most prompts do not work 100% of the time. You want to get some idea of what they can do statistically.

Add at most two keywords at a time. Likewise, generate at least 4 images to assess its effect.

### Using negative prompt

You can use a [universal negative prompt](https://stable-diffusion-art.com/how-to-use-negative-prompts/#Universal_negative_prompt) if you are starting out.

Adding keywords to the negative prompt can be part of the iterative process. The keywords can be objects or body parts you want to avoid (Since v1 models are not very good at rendering hands, it’s not a bad idea to use “hand” in the negative prompt to hide them.)

## Prompting techniques

You can modify a keyword’s importance by switching to a different one at a certain sampling step.

The following syntaxes apply to AUTOMATIC1111 GUI. You can run this GUI with one click using the Colab notebook in the Quick Start Guide. You can also install it on Windows and Mac.

### Keyword weight

(This syntax applies to AUTOMATIC1111 GUI.)

You can adjust the **weight** of a keyword by the syntax (keyword: factor). factor is a value such that less than 1 means less important and larger than 1 means more important.

For example, we can adjust the weight of the keyword dog in the following prompt

> dog, autumn in paris, ornate, beautiful, atmosphere, vibe, mist, smoke, fire, chimney, rain, wet, pristine, puddles, melting, dripping, snow, creek, lush, ice, bridge, forest, roses, flowers, by stanley artgerm lau, greg rutkowski, thomas kindkade, alphonse mucha, loish, norman rockwell.

Increasing the weight of dog tends to generate more dogs. Decreasing it tends to generate fewer. It is not always true for every single image. But it is true in a statistical sense.

This technique can be applied to subject keywords and all categories, such as style and lighting.

### () and [] syntax

(This syntax applies to AUTOMATIC1111 GUI.)

An equivalent way to adjust keyword strength is to use () and []. (keyword) increases the strength of the keyword by a factor of 1.1 and is the same as (keyword:1.1). [keyword] decrease the strength by a factor of 0.9 and is the same as (keyword:0.9).

You can use multiple of them, just like in Algebra… The effect is multiplicative.

**(keyword)** is equivalent to **(keyword: 1.1)**
**((keyword))** is equivalent to **(keyword: 1.21)**
**(((keyword)))** is equivalent to **(keyword: 1.33)**

Similarly, the effects of using multiple [] are:

**[keyword]** is equivalent to **(keyword: 0.9)**
**[[keyword]]** is equivalent to **(keyword: 0.81)**
**[[[keyword]]]** is equivalent to **(keyword: 0.73)**

AUTOMATIC1111 TIP: You can use Ctrl + Up/Down Arrow (Windows) or Cmd + Up/Down Arrow to increase/decrease the weight of a keyword.

### Keyword blending

(This syntax applies to AUTOMATIC1111 GUI.)

You can mix two keywords. The proper term is **prompt scheduling**. The syntax is

> [keyword1 : keyword2: factor]

factor controls at which step keyword1 is switched to keyword2. It is a number between 0 and 1.

For example, if I use the prompt

> Oil painting portrait of [Joe Biden: Donald Trump: 0.5]

for 30 sampling steps.

That means the prompt in steps 1 to 15 is

> Oil painting portrait of Joe Biden

And the prompt in steps 16 to 30 becomes

> Oil painting portrait of Donald Trump

The factor determines when the keyword is changed. it is after 30 steps x 0.5 = 15 steps.

The effect of changing the factor is blending the two presidents to different degrees.

You may have noticed Trump is in a white suit which is more of a Joe outfit. This is a perfect example of a very important rule for keyword blending: **The first keyword dictates the global composition**. The early diffusion steps set the overall composition. The later steps refine details. 

### Blending faces

A common use case is to create a new face with a particular look, borrowing from actors and actresses. For example, [Emma Watson: Amber heard: 0.85], 40 steps is a look between the two:

When carefully choosing the two names and adjusting the factor, we can get the look we want precisely.

Alternatively, you can use **multiple celebrity names** with keyword weights to adjust facial features. For example:

> (Emma Watson:0.5), (Tara Reid:0.9), (Ana de Armas:1.2)

See [this tutorial](https://stable-diffusion-art.com/consistent-face/) if you want to generate a consistent face across multiple images.

### Poor man’s prompt-to-prompt

Using keyword blending, you can achieve effects similar to [prompt-to-prompt](https://prompt-to-prompt.github.io/), generating pairs of highly similar images with edits. The following two images are generated with the same prompt except for a prompt schedule to substitute apple with fire. The seed and number of steps were kept the same.

> holding an [apple: fire: 0.9]
> holding an [apple: fire: 0.2]

The factor needs to be carefully adjusted. How does it work? The theory behind this is the overall composition of the image was set by the early [diffusion process](https://stable-diffusion-art.com/how-stable-diffusion-work/#Diffusion_model). Once the diffusion is trapped in a small space, swapping any keywords won’t have a large effect on the overall image. It would only change a small part.

## Consistent face

Using multiple celebrity names is an easy way to blend two or more faces. The blending will be consistent across images. You don’t even need to use prompt scheduling. When you use multiple names, Stable Diffusion understands it as generating one person but with those facial features.

The following phrase uses multiple names to blend three faces with different weights.

> (Emma Watson:0.5), (Tara Reid:0.9), (Ana de Armas:1.2)

Putting this technique into action, the prompt is:

> (Emma Watson:0.5), (Tara Reid:0.9), (Ana de Armas:1.2), photo of young woman, highlight hair, sitting outside restaurant, wearing dress, rim lighting, studio lighting, looking at the camera, dslr, ultra quality, sharp focus, tack sharp, dof, film grain, Fujifilm XT3, crystal clear, 8K UHD, highly detailed glossy eyes, high detailed skin, skin pores

Here are images with the same prompt:

See this face repeating across the images!

Use multiple celebrity names and keyword weights to carefully tune your desired facial feature. You can also use celebrity names in the negative prompt to avoid facial features you DON’T want.

See more techniques to generate [consistent faces](https://stable-diffusion-art.com/consistent-face/).

## How long can a prompt be?

Depending on what Stable Diffusion service you are using, there could be a maximum number of keywords you can use in the prompt. In the basic Stable Diffusion v1 model, that limit is 75 **tokens**.

Note that tokens are not the same as words. The [CLIP model](https://stable-diffusion-art.com/how-stable-diffusion-work/#Tokenizer) Stable Diffusion automatically converts the prompt into tokens, a numerical representation of words it knows. If you put in a word it has not seen before, it will be broken up into 2 or more sub-words until it knows what it is. The words it knows are called tokens, which are represented as numbers.

For example, dream is one token and beach is another token. But dreambeach is two tokens because the model doesn’t know this word, and so the model breaks the word up to dream and beach which it knows.

### Prompt limit in AUTOMATIC1111

AUTOMATIC1111 has [no token limits](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Features#infinite-prompt-length). If a prompt contains more than 75 tokens, the limit of the CLIP tokenizer, it will start a new chunk of another 75 tokens, so the new “limit” becomes 150. The process can continue forever or until your computer runs out of memory…

Each chunk of 75 tokens is processed independently, and the resulting representations are concatenated before feeding into Stable Diffusion’s [U-Net.](https://stable-diffusion-art.com/how-stable-diffusion-work/#Feeding_embeddings_to_noise_predictor)

In AUTOMATIC1111, You can check the number of tokens by looking at the small box at the top right corner of the prompt input box.

### Starting a new prompt chunk

What if you want to start a new prompt chunk before reaching 75 tokens? Sometimes you want to do that because the token in the beginning of a chunk can be more effective, and you may want to group related keywords in a chunk.

You can use the keyword BREAK to start a chunk. The following prompt uses two chunks to specify the hat is white and the dress is blue.

> photo of a woman in white hat
> BREAK
> blue dress

Without the BREAK, Stable Diffusion is more likely to mix up the color of the hat and the dress.

## Checking keywords

The fact that you see people using a keyword doesn’t mean that it is effective. Like homework, we all copy each other’s prompts, sometimes without much thought.

You can check the effectiveness of a keyword by just using it as a prompt. For example, does the v1.5 model know the American portrait painter John Singer Sargent? Let’s check with the prompt

> John Singer Sargent

How about the Artstation sensation wlop?

> wlop

Well, doesn’t look like it. That’s why you shouldn’t use “by wlop”. That’s just adding noise.

You can use this technique to examine the effect of mixing two or more artists.

> John Singer Sargent, Picasso

## Limiting the variation

To be good at building prompts, you need to think like Stable Diffusion. At its core, it is an image sampler, generating pixel values that we humans likely say it’s legit and good. You can even use it without prompts, and it would generate many unrelated images. In technical terms, this is called unconditioned or unguided diffusion.

The prompt is a way to guide the diffusion process to the sampling space where it matches. I said earlier that a prompt needs to be detailed and specific. It’s because a detailed prompt narrows down the sampling space. Let’s look at an example.

> castle
> castle, blue sky background
> wide angle view of castle, blue sky background

By adding more describing keywords in the prompt, we narrow down the sampling of castles. In We asked for **any image of a castle** in the first example. Then we asked to get only those with a blue sky background. Finally, we demanded it is **taken as a wide-angle photo**.

The more you specify in the prompt, the less variation in the images.

## Association effect

### Attribute association

Some attributes are strongly correlated. When you specify one, you will get the other. Stable Diffusion generates the most likely images that could have an unintended association effect.

Let’s say we want to generate photos of women with **blue eyes**.

> a young female with blue eyes, highlights in hair, sitting outside restaurant, wearing a white outfit, side light

Blue eyes

What if we change to brown eyes?

> a young female with brown eyes, highlights in hair, sitting outside restaurant, wearing a white outfit, side light

Nowhere in the prompts, I specified ethnicity. But because people with blue eyes are predominantly Europeans, Caucasians were generated. Brown eyes are more common across different ethnicities, so you will see a more diverse sample of races.

Stereotyping and bias is a big topic in AI models. I will confine to the technical aspect in this article.

### Association of celebrity names

Every keyword has some unintended associations. That’s especially true for celebrity names. Some actors and actresses like to be in certain poses or wear certain outfits when taking pictures, and hence in the training data. If you think about it, model training is nothing but learning by association. If Taylor Swift (in the training data) always crosses her legs, the model would think leg crossing is Taylor Swift too.

When you use Taylor Swift in the prompt, you may mean to use her face. But there’s an effect of the subject’s pose and outfit too. The effect can be studied by using her name alone as the prompt.

Poses and outfits are global compositions. If you want her face but not her poses, you can use keyword blending to swap her in at a later sampling step.

### Association of artist names

Perhaps the most prominent example of association is seen when using artist names.

The 19th-century Czech painter Alphonse Mucha is a popular occurrence in portrait prompts because the name helps generate interesting embellishments, and his style blends very well with digital illustrations. But it also often leaves a signature circular or dome-shaped pattern in the background. They could look unnatural in outdoor settings.

> Prompt: digital painting of [Emma Watson:Taylor Swift: 0.6] by Alphonse Mucha. (30 steps)

## Embeddings are keywords

[Embeddings](https://stable-diffusion-art.com/embedding/), the result of textual inversion, are nothing but combinations of keywords. You can expect them to do a bit more than what they claim.

Let’s see the following base images of Ironman making a meal without using embeddings.

> Prompt: iron man cooking in kitchen.

Style-Empire is an embedding I like to use because it adds a dark tone to portrait images and creates an interesting lighting effect. Since it was trained on an image with a street scene at night, you can expect it adds some blacks AND perhaps buildings and streets. See the images below with the embedding added.

> Prompt: iron man cooking in kitchen Style-Empire.

Note some interesting effects

* The background of the first image changed to city buildings at night.
* Iron man tends to show his face. Perhaps the training image is a portrait?

So even if an embedding is intended to modify the style, it is just a bunch of keywords and can have unintended effects.

## Effect of custom models

Using a [custom model](https://stable-diffusion-art.com/models/) is the easiest way to achieve a style, guaranteed. This is also a unique charm of Stable Diffusion. Because of the large open-source community, thousands of custom models are freely available.

When using a model, we need to be aware that the meaning of a keyword can change. This is especially true for styles.

Let’s use John Singer Sargent as the prompt with the Stable Diffusion v1.5 model.

Using the DreamShaper with the same prompt, a model fine-tuned for realistic portrait illustrations, we get the following images instead.

The style becomes more realistic. The DreamShaper model has a strong basis for generating clear and pretty woman faces.

Check before you use a style in a custom model. van Gogh may not be van Gogh anymore!

## Region-specific prompts

Do you know you can specify different prompts for different regions of the image?

For example, you can put the moon at the top left or at the top right.

You can do that by using the Regional [Prompter extension](https://stable-diffusion-art.com/regional-prompter/). It’s a great way to control image composition!