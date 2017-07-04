# This file defines derivations built by Hydra
with import ./deps.nix {};

let
  pkgs = import <nixpkgs> {};
  images = import ./image.nix {};
  controller = import ./controller.nix {};

  dockerImageBuildProduct = pkgs.runCommand "docker-image" {} ''
    mkdir $out
    ln -s ${images.dockerContrailApi.out} $out/image.tar.gz
    mkdir $out/nix-support
    echo "file gzip ${images.dockerContrailApi.out}" > $out/nix-support/hydra-build-products
  '';

  dockerPushImage = image:
    let
      repository = image.name;
      registry = "localhost:5000";
    in
      pkgs.runCommand "push-docker-image-${repository}" {
      buildInputs = [ pkgs.jq skopeo ];
      } ''
      # The image generated by nix doesn't contain the manifest and
      # the json image configuration. We generate them and then pushed
      # the image to a registry.

      mkdir temp
      cd temp
      echo "Unpacking image..."
      tar -xf ${image.out}
      chmod a+w ../temp

      LAYER=$(find ./ -name layer.tar)
      LAYER_PATH=$(find -type d -printf %P)
      LAYER_JSON=$(find ./ -name json)
      LAYER_SHA=$(sha256sum $LAYER | cut -d ' ' -f1)

      echo "Creating image config file..."
      cat $LAYER_JSON | jq ". + {\"rootfs\": {\"diff_ids\": [\"sha256:$LAYER_SHA\"], \"type\": \"layers\"}}" > config.tmp
      CONFIG_SHA=$(sha256sum config.tmp | cut -d ' ' -f1)
      mv config.tmp $CONFIG_SHA.json

      echo "Creating image manifest..."
      jq -n "[{\"Config\":\"$CONFIG_SHA.json\",\"RepoTags\":[\"${repository}:latest\"],\"Layers\":[\"$LAYER_PATH/layer.tar\"]}]" > manifest.json

      echo "Packing image..."
      tar -cf image.tar manifest.json $CONFIG_SHA.json $LAYER_PATH

      echo "Pushing image..."
      skopeo --insecure-policy  copy --dest-tls-verify=false --dest-cert-dir=/tmp docker-archive:image.tar docker://${registry}/${repository}
      skopeo --insecure-policy inspect --tls-verify=false --cert-dir=/tmp docker://${registry}/${repository} > $out
    '';
in
  images //
  { contrailApi = controller.contrailApi; } //
  { dockerImage = dockerImageBuildProduct; } //
  { dockerPush = dockerPushImage images.dockerContrailApi; }
