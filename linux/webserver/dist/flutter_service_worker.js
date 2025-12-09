'use strict';
const MANIFEST = 'flutter-app-manifest';
const TEMP = 'flutter-temp-cache';
const CACHE_NAME = 'flutter-app-cache';

const RESOURCES = {"flutter.js": "24bc71911b75b5f8135c949e27a2984e",
"icons/Icon-512.png": "96e752610906ba2a93c65f8abe1645f1",
"icons/Icon-maskable-512.png": "301a7604d45b3e739efc881eb04896ea",
"icons/Icon-192.png": "ac9a721a12bbc803b44f645561ecb1e1",
"icons/Icon-maskable-192.png": "c457ef57daa1d16f64b27b786ec2ea3c",
"manifest.json": "37d3d54545458e6b6896b5fe7ff1faaa",
"javascript/utils.js": "1ff1e7a5f28206c00880a042afe1c3fd",
"javascript/cookies.js": "e7dee9bf275c0b0b0b06bfceb975be8b",
"javascript/webrtc/gstwebrtc-api-3.0.0.min.js": "2b3d1e10ed5e07f331bd57c5aa021279",
"javascript/webrtc/index.html": "15b9832790b85a6702c273948cafb044",
"javascript/webrtc/gstwebrtc-api-3.0.0.esm.js": "f970f046008b41f00f5bb2c16bb624e4",
"javascript/webrtc/gstwebrtc-api-3.0.0.esm.js.map": "53eb2aaad52b244b472090e59545755c",
"javascript/webrtc/gstwebrtc-api-3.0.0.min.js.map": "4de4dbf32e833e95deaba3bc3b729ee7",
"index.html": "7005bdc2cf7084e5a2b354b2e8b3464a",
"/": "7005bdc2cf7084e5a2b354b2e8b3464a",
"assets/shaders/stretch_effect.frag": "40d68efbbf360632f614c731219e95f0",
"assets/shaders/ink_sparkle.frag": "ecc85a2e95f5e9f53123dcaf8cb9b6ce",
"assets/AssetManifest.bin.json": "0449aa16a4930fe19fc8825dab10ee8a",
"assets/assets/documents/README.md": "5e2be0d825aeae70152f329b1a59a03c",
"assets/assets/documents/thesis/Bachelor_Thesis.pdf": "da6370acd55857d876bbbe1ea533c313",
"assets/assets/documents/thesis/Master_Thesis.pdf": "74d340fd6795d61583408e062fa6183b",
"assets/assets/documents/footer/copyRightDe.md": "829eda261c2d372a2e012af5ebdca173",
"assets/assets/documents/footer/cookieDeclarationEn.md": "7c6f38f543bdbfcbd1f452a9b88463bb",
"assets/assets/documents/footer/privacyPolicyDe.md": "d72f1e9de6b38b48a8ba07576f07c278",
"assets/assets/documents/footer/cookieDeclarationDe.md": "35c48d7ed56a83a008ccd9e77ac32ac9",
"assets/assets/documents/footer/privacyPolicyEn.md": "361141e6d00d96512d98f3f5dbb24d2f",
"assets/assets/documents/footer/imprintEn.md": "95fb262f69017433f6fe63146f4a1000",
"assets/assets/documents/footer/contactDe.md": "d0d0304e86390c1320f22dc280750e30",
"assets/assets/documents/footer/contactEn.md": "9083ee1d56ae34a77c79c646001bbc2c",
"assets/assets/documents/footer/declarationOnAccessibilityDe.md": "072531cc6f9a7dd7dcb94d830325fcd6",
"assets/assets/documents/footer/declarationOnAccessibilityEn.md": "0c00586feccb384dc3944c79de229689",
"assets/assets/documents/footer/imprintDe.md": "cfa06236914d6cfe1bd6d48a7da9be56",
"assets/assets/documents/footer/copyRightEn.md": "63e39d908c1205efb89a3ead89d4ab16",
"assets/assets/documents/blog/aiBlogPageEn.md": "fb0598d44fc9e5aed7d3240c2f68889f",
"assets/assets/documents/blog/renderingBlogPageEn.md": "83c7ece070e61d377fd0aa7bb6ad0453",
"assets/assets/documents/blog/aiBlog.css": "80e1e1344a67b2928d00c68bd1a3c1a3",
"assets/assets/documents/blog/AIBlog.pdf": "7a5451c8f7142546f9ad47e53ed30304",
"assets/assets/documents/blog/Untitled.md": "0b9fa4d47ba4a9e5414627633ea9cc1f",
"assets/assets/documents/cv/CV_Jonas_Heinle_english.pdf": "a9cce7d4fa75911d1670131987508c84",
"assets/assets/documents/cv/CV_Jonas_Heinle_german.pdf": "8b26e0fbf7165cf12e5e306b91700ff8",
"assets/assets/images/aiBlog/ScreenshotModernOpenGL.png": "f33a9cfbc53de25d27ef82a2cbb16d41",
"assets/assets/images/aiBlog/Coffee-removebg.png": "a826e8643bb9d1bd74cd4250ae89324e",
"assets/assets/images/aiBlog/ScreenshotWorleyNoise.png": "b9add9c8aa2f119bf679e6f9fcb0fa03",
"assets/assets/images/cats/Summy&Thundy.png": "4460a3c4fac2db56cdad2300e7caedc4",
"assets/assets/images/cats/Summy&Thundy_compressed.png": "4a3d7676b4b28f6e0aee17b6d4788062",
"assets/assets/images/cats/Thundy.jpg": "982205b6355a6dd0784f3e7bd2219349",
"assets/assets/images/funny_programmer.gif": "416475e3b938be32caf8f581a8bda6cc",
"assets/assets/images/barbell.png": "b26f39769714d28d12c1336e6e9cb820",
"assets/assets/images/flat_barbell_6015194.png": "6d0e66d08c8328c9425250628316d2ca",
"assets/assets/images/logo.png": "4998a732d776b4b86412296cddec7b49",
"assets/assets/images/ML_CV.jpeg": "47fee9872b410d12e6c90d0baa350a00",
"assets/assets/images/books/cat-computer.gif": "df8c44a1d20ab367fdcb21880985fd33",
"assets/assets/images/cat-computer.gif": "df8c44a1d20ab367fdcb21880985fd33",
"assets/assets/images/Pages/Error/error404.gif": "8097587e67976b1964ea1cc86b130f4d",
"assets/assets/images/Pages/Data/Book_cover.jpg": "5cc3c69c589ccb3e6fe1c8826bf68214",
"assets/assets/images/Pages/Data/Film_cover.jpg": "fd39a4074534101f8c30abe761dadac9",
"assets/assets/images/Pages/Data/Spiele_cover.jpg": "dab530855cb64937ee51639d77232fbe",
"assets/assets/images/Pages/Data/Quotes_cover.jpg": "8d37cf3cefd2d21523789667612bbf31",
"assets/assets/images/Pages/AboutMe/paypal.jpg": "b7aa01b28265436894953729238d6713",
"assets/assets/images/Pages/AboutMe/Paypal_QR_Code.png": "f1d2a3af766e404ac6763b2cfb6b753d",
"assets/assets/images/Pages/AboutMe/Coffee-removebg.png": "a826e8643bb9d1bd74cd4250ae89324e",
"assets/assets/images/Pages/AboutMe/Bewerbungsbilder/22e2a944.jpg": "cf4345dee11fc701fd8fe52855f1fd80",
"assets/assets/images/Pages/AboutMe/Bewerbungsbilder/a95a64ca.jpg": "7b432d47da41362a46696ed8c31dd3fa",
"assets/assets/images/Pages/AboutMe/Bewerbungsbilder/a95a64ca-min.jpg": "8e618f8922359e7cd897029fb4a5ccb9",
"assets/assets/images/Pages/AboutMe/Bewerbungsbilder/579706fe.jpg": "434ad3bd316eb682922ffff5338f696d",
"assets/assets/images/Pages/AboutMe/Bewerbungsbilder/a95a64ca_runterskaliert.jpg": "1feebe9d8935dbe4692e94322c262259",
"assets/assets/images/Pages/Blog/VulkanRenderer/Screenshot.png": "602146eec3bb45f82ca4bbbd182919a3",
"assets/assets/images/Pages/Blog/VulkanRenderer/Engine_logo.bmp": "5633c3756649ded7ce14a36b0122dfa7",
"assets/assets/images/Pages/Blog/VulkanRenderer/faviconNew.ico": "2ac39a3c33eb3fe9a78107b7590e9d79",
"assets/assets/images/Pages/Blog/VulkanRenderer/ScreenshotVulkanPathTracing.png": "61243134cf7a4fce534ad27a8bcdad6f",
"assets/assets/images/Pages/Blog/VulkanRenderer/Screenshot3.png": "61243134cf7a4fce534ad27a8bcdad6f",
"assets/assets/images/Pages/Blog/VulkanRenderer/glm_logo.png": "84f1403de9944de04c278996e9489aa2",
"assets/assets/images/Pages/Blog/VulkanRenderer/Screenshot1.png": "d72611044807ba1ae16103e018768347",
"assets/assets/images/Pages/Blog/VulkanRenderer/logo.png": "4998a732d776b4b86412296cddec7b49",
"assets/assets/images/Pages/Blog/VulkanRenderer/Engine_logo.png": "ff46ee05e02c6169ac9985cbf7905d51",
"assets/assets/images/Pages/Blog/VulkanRenderer/logo_gui.png": "6eb497f233bc33bb4aac05b008876be0",
"assets/assets/images/Pages/Blog/VulkanRenderer/Screenshot2.png": "5eccfff7fe5fcffadb7e32fce7d02596",
"assets/assets/settings/user_settings/user_skills_en.json": "d7998196ec8658d5c2b19749a61f64ff",
"assets/assets/settings/user_settings/global_user_settings.json": "9397d904141533ba7bd434e41ad154e3",
"assets/assets/settings/user_settings/user_skills_de.json": "a1cdc56408d85c7df157d42a6f1b1fe7",
"assets/assets/settings/blog_settings.json": "f18799212e74f9caa6820616fb89cae1",
"assets/assets/settings/my_two_cents_settings.json": "405d0f25f68841a1c581a34d2b40b9ec",
"assets/assets/settings/app_settings.json": "692ea3fbe7d608fa49312d92964df3a2",
"assets/fonts/MaterialIcons-Regular.otf": "3a409dc1c1f2f7fddd8443bdd0066286",
"assets/NOTICES": "43da3d97b6590ebdd7efc7b62894f488",
"assets/packages/cupertino_icons/assets/CupertinoIcons.ttf": "33b7d9392238c04c131b6ce224e13711",
"assets/packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Solid-900.otf": "4894d8ad2119c98d27a714a77ebb7e61",
"assets/packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Brands-Regular-400.otf": "4ef69e4e7a94e0f1ba5e4a5e7fe9c3af",
"assets/packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Regular-400.otf": "b2703f18eee8303425a5342dba6958db",
"assets/FontManifest.json": "c75f7af11fb9919e042ad2ee704db319",
"assets/AssetManifest.bin": "e8b18fefc972d675cf1149f56ec9f52d",
"canvaskit/chromium/canvaskit.wasm": "a726e3f75a84fcdf495a15817c63a35d",
"canvaskit/chromium/canvaskit.js": "a80c765aaa8af8645c9fb1aae53f9abf",
"canvaskit/chromium/canvaskit.js.symbols": "e2d09f0e434bc118bf67dae526737d07",
"canvaskit/skwasm_heavy.wasm": "b0be7910760d205ea4e011458df6ee01",
"canvaskit/skwasm_heavy.js.symbols": "0755b4fb399918388d71b59ad390b055",
"canvaskit/skwasm.js": "8060d46e9a4901ca9991edd3a26be4f0",
"canvaskit/canvaskit.wasm": "9b6a7830bf26959b200594729d73538e",
"canvaskit/skwasm_heavy.js": "740d43a6b8240ef9e23eed8c48840da4",
"canvaskit/canvaskit.js": "8331fe38e66b3a898c4f37648aaf7ee2",
"canvaskit/skwasm.wasm": "7e5f3afdd3b0747a1fd4517cea239898",
"canvaskit/canvaskit.js.symbols": "a3c9f77715b642d0437d9c275caba91e",
"canvaskit/skwasm.js.symbols": "3a4aadf4e8141f284bd524976b1d6bdc",
"favicon.png": "6adc8b712c6c6ee3b8901fac0018497c",
"css/loading_animation.css": "e4d6a57fe79ce8602b324df93720422e",
"css/cookie.css": "007a825eff0686ce6f592aff77c5a800",
"flutter_bootstrap.js": "c3c0440e90471b1890f359ac0f7abc28",
"version.json": "c9fd5230ed7847efbbd471d524e0e330",
"main.dart.js": "71e677aae97fefbd3b178af60662bfc5"};
// The application shell files that are downloaded before a service worker can
// start.
const CORE = ["main.dart.js",
"index.html",
"flutter_bootstrap.js",
"assets/AssetManifest.bin.json",
"assets/FontManifest.json"];

// During install, the TEMP cache is populated with the application shell files.
self.addEventListener("install", (event) => {
  self.skipWaiting();
  return event.waitUntil(
    caches.open(TEMP).then((cache) => {
      return cache.addAll(
        CORE.map((value) => new Request(value, {'cache': 'reload'})));
    })
  );
});
// During activate, the cache is populated with the temp files downloaded in
// install. If this service worker is upgrading from one with a saved
// MANIFEST, then use this to retain unchanged resource files.
self.addEventListener("activate", function(event) {
  return event.waitUntil(async function() {
    try {
      var contentCache = await caches.open(CACHE_NAME);
      var tempCache = await caches.open(TEMP);
      var manifestCache = await caches.open(MANIFEST);
      var manifest = await manifestCache.match('manifest');
      // When there is no prior manifest, clear the entire cache.
      if (!manifest) {
        await caches.delete(CACHE_NAME);
        contentCache = await caches.open(CACHE_NAME);
        for (var request of await tempCache.keys()) {
          var response = await tempCache.match(request);
          await contentCache.put(request, response);
        }
        await caches.delete(TEMP);
        // Save the manifest to make future upgrades efficient.
        await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
        // Claim client to enable caching on first launch
        self.clients.claim();
        return;
      }
      var oldManifest = await manifest.json();
      var origin = self.location.origin;
      for (var request of await contentCache.keys()) {
        var key = request.url.substring(origin.length + 1);
        if (key == "") {
          key = "/";
        }
        // If a resource from the old manifest is not in the new cache, or if
        // the MD5 sum has changed, delete it. Otherwise the resource is left
        // in the cache and can be reused by the new service worker.
        if (!RESOURCES[key] || RESOURCES[key] != oldManifest[key]) {
          await contentCache.delete(request);
        }
      }
      // Populate the cache with the app shell TEMP files, potentially overwriting
      // cache files preserved above.
      for (var request of await tempCache.keys()) {
        var response = await tempCache.match(request);
        await contentCache.put(request, response);
      }
      await caches.delete(TEMP);
      // Save the manifest to make future upgrades efficient.
      await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
      // Claim client to enable caching on first launch
      self.clients.claim();
      return;
    } catch (err) {
      // On an unhandled exception the state of the cache cannot be guaranteed.
      console.error('Failed to upgrade service worker: ' + err);
      await caches.delete(CACHE_NAME);
      await caches.delete(TEMP);
      await caches.delete(MANIFEST);
    }
  }());
});
// The fetch handler redirects requests for RESOURCE files to the service
// worker cache.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== 'GET') {
    return;
  }
  var origin = self.location.origin;
  var key = event.request.url.substring(origin.length + 1);
  // Redirect URLs to the index.html
  if (key.indexOf('?v=') != -1) {
    key = key.split('?v=')[0];
  }
  if (event.request.url == origin || event.request.url.startsWith(origin + '/#') || key == '') {
    key = '/';
  }
  // If the URL is not the RESOURCE list then return to signal that the
  // browser should take over.
  if (!RESOURCES[key]) {
    return;
  }
  // If the URL is the index.html, perform an online-first request.
  if (key == '/') {
    return onlineFirst(event);
  }
  event.respondWith(caches.open(CACHE_NAME)
    .then((cache) =>  {
      return cache.match(event.request).then((response) => {
        // Either respond with the cached resource, or perform a fetch and
        // lazily populate the cache only if the resource was successfully fetched.
        return response || fetch(event.request).then((response) => {
          if (response && Boolean(response.ok)) {
            cache.put(event.request, response.clone());
          }
          return response;
        });
      })
    })
  );
});
self.addEventListener('message', (event) => {
  // SkipWaiting can be used to immediately activate a waiting service worker.
  // This will also require a page refresh triggered by the main worker.
  if (event.data === 'skipWaiting') {
    self.skipWaiting();
    return;
  }
  if (event.data === 'downloadOffline') {
    downloadOffline();
    return;
  }
});
// Download offline will check the RESOURCES for all files not in the cache
// and populate them.
async function downloadOffline() {
  var resources = [];
  var contentCache = await caches.open(CACHE_NAME);
  var currentContent = {};
  for (var request of await contentCache.keys()) {
    var key = request.url.substring(origin.length + 1);
    if (key == "") {
      key = "/";
    }
    currentContent[key] = true;
  }
  for (var resourceKey of Object.keys(RESOURCES)) {
    if (!currentContent[resourceKey]) {
      resources.push(resourceKey);
    }
  }
  return contentCache.addAll(resources);
}
// Attempt to download the resource online before falling back to
// the offline cache.
function onlineFirst(event) {
  return event.respondWith(
    fetch(event.request).then((response) => {
      return caches.open(CACHE_NAME).then((cache) => {
        cache.put(event.request, response.clone());
        return response;
      });
    }).catch((error) => {
      return caches.open(CACHE_NAME).then((cache) => {
        return cache.match(event.request).then((response) => {
          if (response != null) {
            return response;
          }
          throw error;
        });
      });
    })
  );
}
