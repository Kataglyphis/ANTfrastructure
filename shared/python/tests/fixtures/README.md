# Upload artifact ZIP fixture

`upload-artifact-v7.0.2-flat.zip` was created offline with the ZIP writer bundled
in `actions/upload-artifact` v7.0.2, action commit
`cf430e030ddbb5b0abf93d22962f4752f3646cd9`. Its `dist/upload/index.js` has Git
blob ID `7b3f92ae681d6eeca5f5e5e4cf892ad0dfb254ea`. A harness called the bundled
`getUploadZipSpecification` and `createZipUploadStream` functions at compression
level 6 with three flat synthetic package files. The ZIP SHA-256 is
`21c25e4fab1ebe73d93e0709ab4ba293706fc3ab850c6762aac236ef9e9a8b93`.

The fixture tests the local writer's archive against preparation and staging. It
does not exercise GitHub upload or download, receipt authenticity, installation,
or GPU hardware. Regenerate it and update the pinned digest when changing the
workflow's upload action version.
