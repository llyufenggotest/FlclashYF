import 'groups_owner_setup_test.dart' as owner;

// Run the same owner/config/session/CAS race suite through production startup,
// not just the bare ProviderContainer that missed the bootstrap regression.
void main() => owner.main(productionBootstrap: true);
