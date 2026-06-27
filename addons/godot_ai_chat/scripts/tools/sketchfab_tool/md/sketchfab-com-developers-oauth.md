Sketchfab for Developers

# Sketchfab Login (OAuth 2.0)

We recommend using Sketchfab Login to improve the UX of your app.
Users can connect to their Sketchfab account and publish 3D content on Sketchfab without leaving your app.


Sketchfab Login uses [OAuth 2.0](https://oauth.net/2/), the industry standard for connecting apps and accounts.


## Table of contents

- [How it works](https://sketchfab.com/developers/oauth#how-it-works)
- [Registering your app](https://sketchfab.com/developers/oauth#registering-your-app)
- [Implementing Sketchfab Login in your app](https://sketchfab.com/developers/oauth#implement-login)
- [Making authenticated calls to the API](https://sketchfab.com/developers/oauth#making-authenticated-calls)
- [Renewing the access token](https://sketchfab.com/developers/oauth#renewing-access-token)
- [Examples](https://sketchfab.com/developers/oauth#examples)

## How it works

### Standard flow

The **first time only**, users connect their Sketchfab account to your app, in 3 simple steps using an Implicit or Authorization Code workflow:


- **Step 1**: Inside your app, the user opens a web window to log into their Sketchfab account.
- **Step 2**: They authorize your app to access their account in the same window.
- **Step 3**: Once authorized, your app receives a token to publish and access 3D content on Sketchfab.

![Sketchfab OAuth workflow standard](https://static.sketchfab.com/static/builds/web/dist/static/assets/images/pages/developers/5523571d86c220e420e52ec8bf5a9617-v2.png)

### Alternative flow

When the regular workflow can not be implemented, your app can ask the user for their Sketchfab username and password.
This flow is **less secure** than the standard flow. A typical use case is applications that cannot open a web browser.


![Sketchfab OAuth workflow alternative](https://static.sketchfab.com/static/builds/web/dist/static/assets/images/pages/developers/c08440b0200ce662e15bd835d53170cb-v2.png)

### What if users do not have a Sketchfab account?

If your users do not have a Sketchfab account yet, they can create one "on the fly" by providing a username, e-mail and password or use their existing Facebook, Twitter or Google accounts.
During signup, users can choose to share automatically models to Facebook.


![Sketchfab OAuth workflow alternative](https://static.sketchfab.com/static/builds/web/dist/static/assets/images/pages/developers/f6e6ad8c8f5e5fe5f989e1584d182f32-v2.png)

### Use case: Publishing 3D models from your app to Sketchfab and Facebook

Sketchfab is integrated into Facebook as an authorized embed source.
Your app can leverage this integration to publish 3D content on Facebook via Sketchfab.


![Sketchfab OAuth workflow alternative](https://static.sketchfab.com/static/builds/web/dist/static/assets/images/pages/developers/372dfb1fbbf320e0ef3ed917d17f1c6d-v2.png)

## Registering your app

Before implementing Sketchfab Login, you need to register your app.
To register your app, simply
[contact us](https://support.fab.com/s/?ProductOrigin=Sketchfab)
with the following information:


1. [Application name](https://sketchfab.com/developers/oauth#register-app-name)
2. [Grant type](https://sketchfab.com/developers/oauth#register-grant-type)
3. [Redirect URI](https://sketchfab.com/developers/oauth#register-redirect-uri)
4. [Username](https://sketchfab.com/developers/oauth#register-username)

In return, you will be provided a **Client ID** and **Client Secret**.
Obviously, the client secret must remain secret.


### 1\. Application name

Users will see this name when they are asked to authorize your app.


### 2\. Grant type

**Authorization Code**, **Implicit**, or **Username/Password**.
The OAuth Authorization grant type will be determined by the type of your app: server-side app, javascript app, mobile app, etc.


### 3\. Redirect URI

At the end of the authorization process, users will be redirected to this URI, where you app can obtain the access token.
This should be a secure HTTPS URI if possible. Multiple redirect URIs are supported.


We do not support reverse DNS notation ( `com.example.app:/path` ) or custom app protocols ( `myapp://path` ) for the redirect URI.
You can use an IP address with a listening port ( `http://127.0.0.1:port` ), or `localhost`.
Another alternative is to use a redirect URI on your server/domain which then redirects to your custom protocol.


A common workflow for standalone apps is to open the OAuth page in an iframe, redirect to something
like `localhost`, and have your native code catch the iframe's URI change to get the token.


### 4\. Username

Users will see this username as the application's author in their list of
[Connected apps](https://sketchfab.com/settings/apps).


## Implementing Sketchfab Login in your app

The way you will implement Sketchfab Login will depend on the **Authorization grant type**.
There are 3 possible Authorization grant types:


- [Authorization code](https://sketchfab.com/developers/oauth#implement-auth-code)
- [Implicit](https://sketchfab.com/developers/oauth#implement-implicit)
- [Username/Password](https://sketchfab.com/developers/oauth#implement-password)

### Grant type: Authorization code

The Authorization code grant type is typically for server-side applications,
where the source code is not accessible by end-users.
These apps must guarantee the confidentiality of the Client Secret.


Here's the typical flow:

1. Your app displays a "Sketchfab Login" link:
    `https://sketchfab.com/oauth2/authorize/?response_type=code&client_id=[CLIENT_ID]&redirect_uri=[REDIRECT_URI]`
2. User clicks on the link

3. User is prompted to authorize your app

4. User is redirected back to your site with an authorization code:
    `https://example.com/oauth2_redirect?code=123456789`
5. Your server exchanges the authorization code for an access token by
    making a **POST** request to `https://sketchfab.com/oauth2/token/`.
    The request must have the `"Content-Type"` header set to `"application/x-www-form-urlencoded"`
    and the request body must include the following data:

   - `'grant_type': 'authorization_code'`
   - `'code': [AUTHORIZATION_CODE]`
   - `'client_id': [CLIENT_ID]`
   - `'client_secret': [CLIENT_SECRET]`
   - `'redirect_uri': [REDIRECT_URI]`

### Grant type: Implicit

The Implicit grant type is for applications where the confidentiality
of the Client Secret is not guaranteed, like browser-based apps or mobile apps.


Here's the typical flow:

- Your app displays a "Sketchfab Login" button

- User clicks on the button, which opens the authorization URL:
`https://sketchfab.com/oauth2/authorize/?state=123456789&response_type=token&client_id=[CLIENT_ID]`
- User is prompted to authorize your app

- User is redirected to your Redirect URI where your app can retrieve the access token


### Grant type: Username/Password

Also called "Resource owner password credentials grant", this workflow is **less secure** because it directly exchanges a username and password in exchange for an access token.
It should only be used when another grant type cannot be used, for example in an application that has no access to a web browser context.


Here's the typical flow:

- User enters fields in your app for their Sketchfab credentials (email and password).

- User submits the login and you pass the email and password directly to the authorization endpoint by making a **POST** request with the following attributes:


**URL**

```
https://sketchfab.com/oauth2/token/
```

**POST Data**

```
grant_type=password&username=EMAIL_ADDRESS&password=PASSWORD
```


EMAIL\_ADDRESS and PASSWORD are the Sketchfab credentials provided by the end user.




**Authorization HTTP header**

```
Authorization: Basic CREDENTIALS
```


CREDENTIALS is the [base64 encoded string of your app credentials](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Authorization), separated by a colon, i.e. base64(client\_id:client\_secret).


- You retrieve the access token directly in the response.


## Making authenticated calls to the API

Once your app has obtained an access token, it can make authenticated
calls to the Sketchfab API, on behalf of the user.


To make an authenticated call to the Data API, simply add the
Authorization header to your HTTP request:


```
Authorization: Bearer [ACCESS_TOKEN]
```

Here's an example with CURL that returns the user profile info:


```
curl -H "Authorization: Bearer 2rvHcchHw1CSX42Hgo1ArYa5MqsdVH" https://api.sketchfab.com/v3/me
```

## Renewing the access token

Access tokens last 1 month. When they expire, users have to authorize your app again. However, the **access token**
comes with a **renew token** that can be used to obtain a new **access token** before the expiry date.


When using the Implicit grant workflow, there is no refresh token. You must repeat the exchange for an access token each time.
If you use the `approval_prompt=auto` parameter when hitting the authorization endpoint,
this will bypass the authorization if the user already agreed to allow the app to use its sketchfab account.


To renew an access token, make a **POST** request to
`https://sketchfab.com/oauth2/token/` with the following data:


- `'grant_type': 'refresh_token'`
- `'client_id': [CLIENT_ID]`
- `'client_secret': [CLIENT_SECRET]`
- `'refresh_token': [REFRESH_TOKEN]`

## Examples

- [Python](https://sketchfab.com/developers/oauth/python)
- [PHP](https://sketchfab.com/developers/oauth/php)