Sketchfab for Developers

# Downloading models

Downloading models into your app will usually require the following steps:

1. [Authenticating the user](https://sketchfab.com/developers/download-api/downloading-models#authenticating-the-user)
2. [Requesting a download](https://sketchfab.com/developers/download-api/downloading-models#requesting-a-download)
3. [Download the archive](https://sketchfab.com/developers/download-api/downloading-models#downloading-the-archive)
4. [Unzipping the archive](https://sketchfab.com/developers/download-api/downloading-models#unzipping-the-archive)
5. [Loading the model](https://sketchfab.com/developers/download-api/downloading-models#loading-the-model)

## Authenticating the user

Downloading a model requires the user to be authenticated with a Sketchfab account.
See [Sketchfab Login (OAuth 2.0) documentation](https://sketchfab.com/developers/oauth) for more information.

## Requesting a download

To prevent abuse, models cannot be downloaded directly. Your app must request a download first.

To request a download, make an HTTP request:

- Method: `GET`
- URL: `https://api.sketchfab.com/v3/models/{UID}/download` (replace `{UID}` by the actual model `uid`)
- With `Authorization` header for authentication.

Example with `curl`:

```
curl 'https://api.sketchfab.com/v3/models/{UID}/download' -H 'authorization: Bearer {INSERT_USER_OAUTH_ACCESS_TOKEN}'
```

The JSON response will contain temporary links to the downloadable glTF archive and USDZ file, if available.

```json
{
    "gltf": {
        "url": "https://sketchfab-prod-media.s3.amazonaws.com/archives/799f8c4511f84fab8c3f12887f7e6b36/gltf/...",
        "size": 45388265,
        "expires": 300
    },
    "usdz": {
        "url": "https://sketchfab-prod-media.s3.amazonaws.com/archives/799f8c4511f84fab8c3f12887f7e6b36/usdz/...",
        "size": 6394777,
        "expires": 300
    }
}
```

## Downloading the archive

Once you’ve obtained a link to download an archive, you can download it by making a HTTP GET request.
No authentication is required. The link already contains a token that has a short expiration date.
Also, for that reason, **you should not cache** the URL.

## Unzipping the archive

The USDZ file is supplied directly. However, the glTF download is a ZIP archive. It will usually contain the following files:

```
.
├── scene.bin
├── scene.gltf
└── textures
    └── model_baseColor.jpeg
```

- `scene.bin`: binary buffer containing geometry, animation and skins
- `scene.gltf`: main file in glTF 2.0 format
- `textures/`: folder containing textures

## Loading the model

Loading the glTF or USDZ model will depend on your application. The Khronos Group has a list of implementations on the
[glTF Github repository](https://github.com/KhronosGroup/glTF).

iOS devices can open USDZ file URLs directly in Safari. You can find more detailed USDZ documentation from
[Apple](https://developer.apple.com/augmented-reality/)
and [Pixar](https://graphics.pixar.com/usd/docs/Usdz-File-Format-Specification.html).