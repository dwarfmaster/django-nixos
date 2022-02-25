{
  outputs = { self }:
  {
    nixosModules.django = import ./.;
  };
}
