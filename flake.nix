{
  outputs = { self }:
  {
    lib = {
      mkNixosModule = args: (import ./. args).nixosModule;
    };
  };
}
