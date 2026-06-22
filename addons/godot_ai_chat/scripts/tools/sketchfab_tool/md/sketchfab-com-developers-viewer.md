Sketchfab for Developers

# Viewer API

The Viewer API lets you build web apps on top of Sketchfab’s 3D viewer.
With the API, you can control the viewer in JavaScript. It provides functions for starting, stopping the viewer, moving the camera, taking screenshots and more.

## Getting started

To use the viewer API in a web page, follow these 3 steps:

- Insert this script in your page: [sketchfab-viewer-1.12.1.js](https://static.sketchfab.com/api/sketchfab-viewer-1.12.1.js)
- Add an empty `iframe`
- Initialize the viewer

Here is a ready to use example:

```html
<!DOCTYPE HTML>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sketchfab Viewer API example</title>

    <!-- Insert this script -->
    <script type="text/javascript" src="https://static.sketchfab.com/api/sketchfab-viewer-1.12.1.js"></script>
</head>

<body>
    <!-- Insert an empty iframe with attributes -->
    <iframe src="" id="api-frame" allow="autoplay; fullscreen; xr-spatial-tracking" xr-spatial-tracking execution-while-out-of-viewport execution-while-not-rendered web-share allowfullscreen mozallowfullscreen="true" webkitallowfullscreen="true"></iframe>

    <!-- Initialize the viewer -->
    <script type="text/javascript">
    var iframe = document.getElementById( 'api-frame' );
    var uid = '7w7pAfrCfjovwykkEeRFLGw5SXS';

    // By default, the latest version of the viewer API will be used.
    var client = new Sketchfab( iframe );

    // Alternatively, you can request a specific version.
    // var client = new Sketchfab( '1.12.1', iframe );

    client.init( uid, {
        success: function onSuccess( api ){
            api.start();
            api.addEventListener( 'viewerready', function() {

                // API is ready to use
                // Insert your code here
                console.log( 'Viewer is ready' );

            } );
        },
        error: function onError() {
            console.log( 'Viewer error' );
        }
    } );
    </script>
</body>
</html>
```

NOTE: Firefox does not support certain tasks for iframes with `style="display:none"`, like adding event listeners. A possible workaround is to add a class that changes the visibility. Here is an example:

```html
<!DOCTYPE HTML>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sketchfab Viewer API example</title>

    <script type="text/javascript" src="https://static.sketchfab.com/api/sketchfab-viewer-1.12.1.js"></script>
    <style>
    // Hidden class
    .hidden {
        visibility: hidden;
        height: 0;
        width: 0;
    }
    </style>
</head>

<body>
  <!-- Insert an empty iframe with attrubutes, hidden by default using a class-->
  <iframe class="hidden" src="" id="api-frame" allow="autoplay; fullscreen; xr-spatial-tracking" xr-spatial-tracking execution-while-out-of-viewport execution-while-not-rendered web-share allowfullscreen mozallowfullscreen="true" webkitallowfullscreen="true" ></iframe>

  <!-- Initialize the viewer -->
  <script type="text/javascript">

    var iframe = document.getElementById( 'api-frame' );

        var uid = '731235038f6945d19f10d9331b78ea09';
        var client = null;

        function loadmodel() {
            document.addEventListener('load', () => console.log( 'viewerready' ));

            // By default, the latest version of the viewer API will be used.
            var client = new Sketchfab( iframe );

            // Alternatively, you can request a specific version.
            // var client = new Sketchfab( '1.12.0', iframe );

            client.init( uid, {
                success: function onSuccess( api ) {
                    console.log( 'Success' );
                    api.load();
                    api.start();

                    api.addEventListener( 'viewerready', function() {
                        console.log( 'Viewer is ready' );
                        // once the viewer is ready, show the iframe
                        let $apiFrame = document.getElementById( 'api-frame' );
                        $apiFrame.classList.remove( 'hidden' ); // Remove hidden class
                    } );
                },
                error: function onError( callback ) {
                    console.log( this.error );
                }
            } );
        }
  </script>

  <button onclick="loadmodel()">Click me to load model and show iframe.</button>
</body>

</html>
```

NOTE: In order to load correctly, the Sketchfab viewer must run various scripts, access browser cookies, and make requests to other resources on Sketchfab’s servers. If your website sandboxes iframes for security purposes, you must lift certain restrictions. This is very common in various WordPress configurations, for example. To ensure all viewer features function correctly, and to abide by our terms of use, you should include the following values in the `sandbox` attribute:

- `allow-scripts`
- `allow-same-origin`
- `allow-popups`
- `allow-forms`

```html
<iframe src="" id="api-frame" sandbox="allow-scripts allow-same-origin allow-popups allow-forms" allow="autoplay; fullscreen; xr-spatial-tracking" xr-spatial-tracking execution-while-out-of-viewport execution-while-not-rendered web-share allowfullscreen mozallowfullscreen="true" webkitallowfullscreen="true"></iframe>
```

[Learn more about these restrictions in our Help Center](https://support.fab.com/s/article/Compatibility).

## Documentation

- [Initialization and options](https://sketchfab.com/developers/viewer/initialization)
- [API Functions](https://sketchfab.com/developers/viewer/functions)
- [Examples](https://sketchfab.com/developers/viewer/examples)