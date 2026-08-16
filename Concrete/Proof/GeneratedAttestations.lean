import Concrete.Proof.DefinitionIdentity

/-!
# Generated attestation references — do not edit

Emitted by `scripts/gen/attestation_refs.sh` from the attestation manifest, which is itself
derived from compiler-produced subject facts. A proof author SELECTS one of these symbols; the
components are never written by hand.

`Except`-typed because `of?` validates and the constructor is private: a reference that fails
validation stays a refusal rather than becoming a value.
-/

namespace Concrete.Proof.GeneratedAttestations

def ctTagFns_62673cb6_ct_compare : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "62673cb61d810ae35bae364325a7b305" "constant_time_tag" "ct_compare" "18f6e83241d4e9da29cc8cd88d604da0"
def empty_245b5b0c_weak : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "245b5b0cf5fe0a043eaff83aa90dcb73" "cn" "weak" "ff19cefd91e9ef7261e5d696e6228cad"
def cryptoFns_5afbb48c_compute_tag : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "5afbb48c233743e666134f351e8a5e28" "main" "compute_tag" "8fdb09fce36c5df91cdb5fee3c00e35d"
def cryptoFns_5afbb48c_verify_tag : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "5afbb48c233743e666134f351e8a5e28" "main" "verify_tag" "20035d4f9ef9b58229a6fa855cbfbaa3"
def cryptoFns_5afbb48c_check_nonce : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "5afbb48c233743e666134f351e8a5e28" "main" "check_nonce" "0a3ca2002a335ffd62b6cd22edad6146"
def cryptoFns_5afbb48c_verify_message : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "5afbb48c233743e666134f351e8a5e28" "main" "verify_message" "424aecbf3aafee722fe95c69fb8b1c25"
def elfFns_ee5cad85_check_magic : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ee5cad85c19e737f5adb0664fcf9c059" "main" "check_magic" "a774a2e10d4c812456c99912239a7a81"
def elfFns_ee5cad85_check_class : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ee5cad85c19e737f5adb0664fcf9c059" "main" "check_class" "e5a6873b3e7f463367da16bc68f2cbbf"
def elfFns_ee5cad85_check_data : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ee5cad85c19e737f5adb0664fcf9c059" "main" "check_data" "b8a148bbb74cfaf7852c74289a803990"
def elfFns_ee5cad85_check_version : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ee5cad85c19e737f5adb0664fcf9c059" "main" "check_version" "b24dd48ad33452aac540f4fbd34f4908"
def elfFns_ee5cad85_validate_header : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ee5cad85c19e737f5adb0664fcf9c059" "main" "validate_header" "98a73d3ab40b6c8bff43aec13289c06a"
def ctTagFns_404dc2c1_ct_compare : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "404dc2c1dea3a3819db69464378db145" "demo" "ct_compare" "4d81ef861a6be6f536dae068b2052b79"
def empty_241230cb_ch : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "241230cb9fadb24763d83fc58e421bc0" "hmac_sha256" "ch" "f58b438c3db9c748789c8de68945fdea"
def ctTagFns_13c8e415_ct_compare : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "13c8e4151b399c089fad1a4124686597" "constant_time_tag" "ct_compare" "93ab28850d90691e47ac5af7685e9185"
def fixedCapacityFns_7ffbd092_ring_new : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "7ffbd092063dcc88fde1cea31a7ff2b9" "fixed_capacity" "ring_new" "32b00d8bfe666e62cbf0fc8b1f214aa5"
def fixedCapacityFns_7ffbd092_ring_contains : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "7ffbd092063dcc88fde1cea31a7ff2b9" "fixed_capacity" "ring_contains" "a7edaad35c68e6208cda2a68675eabcc"
def fixedCapacityFns_7ffbd092_ring_push : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "7ffbd092063dcc88fde1cea31a7ff2b9" "fixed_capacity" "ring_push" "0f72c306156fe4290388c7a40dede638"
def fixedCapacityFns_7ffbd092_compute_tag : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "7ffbd092063dcc88fde1cea31a7ff2b9" "fixed_capacity" "compute_tag" "5795ae892b334d8b71693973e8f594c5"
def empty_eda14896_sha256_init : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_init" "1cbbcac2dedb20c50ca91b1953ab562f"
def empty_eda14896_ch : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "ch" "3e315e17b9a1420dc0c9c4988af52511"
def shaFns_eda14896_sha256_schedule : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_schedule" "b40af686e1947479a7135f852e1e0f36"
def shaFns_eda14896_sha256_round : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_round" "629f9b2876a77f0f5d52a860659daeb8"
def shaFns_eda14896_sha256_compress : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_compress" "db23b155922cb4251360f8f6ba63708d"
def shaFns_eda14896_sha256_compress_at : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_compress_at" "0419685e7ed4f0816654b1ddf3a67c43"
def shaFns_eda14896_state_to_bytes : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "state_to_bytes" "9744d6bcb60e617a310af956a8ba1b6a"
def shaFns_eda14896_sha256_hash : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_hash" "a75e1f52a094df0bfbbb0b3f5d9bb0e1"
def shaFns_eda14896_hmac_sha256 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "hmac_sha256" "3c91b6c0721b1532979b0ab5071d8115"
def parseValidateFns_ceac11a8_validate_version : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_version" "5eea51e813c69ef88321a943434cf957"
def parseValidateFns_ceac11a8_validate_header_fields : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_header_fields" "94f8271c82b0833bb9b317f8342aa7f0"
def parseValidateFns_ceac11a8_parse_header : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "parse_header" "a18adda69efda6f636be5dc8bb3f8aeb"
def empty_5a806eef_put : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "5a806eeff39331229da508fd010bc9d9" "arr" "put" "74839d8db744f8ea74fe51737d89c273"
def combineFns_214cb623_inc : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "214cb6238f62b3c23093752c737709ba" "calls" "inc" "697ea521ed81fbf8df819cc45438561d"
def combineFns_214cb623_dbl : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "214cb6238f62b3c23093752c737709ba" "calls" "dbl" "c3f254410bdebc8d14050f5087629bf0"
def combineFns_214cb623_combine : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "214cb6238f62b3c23093752c737709ba" "calls" "combine" "75e3325a189ef34014260cc046888b42"
def combineFns_9077cfbf_inc : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "9077cfbf791a20f26684e2b6c7b13f85" "calls" "inc" "697ea521ed81fbf8df819cc45438561d"
def combineFns_9077cfbf_combine : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "9077cfbf791a20f26684e2b6c7b13f85" "calls" "combine" "75e3325a189ef34014260cc046888b42"
def combineFns_d9933ee2_inc : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "d9933ee23eb7a3569c662bfcfb96d998" "calls" "inc" "697ea521ed81fbf8df819cc45438561d"
def combineFns_d9933ee2_combine : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "d9933ee23eb7a3569c662bfcfb96d998" "calls" "combine" "75e3325a189ef34014260cc046888b42"
def empty_1f509cdd_sum4 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "1f509cdd701c2651156efb6e0566eb8e" "fold" "sum4" "6b0b02cd3611f49788a6f88669115d5f"
def empty_c51ffa61_with_ghost : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "c51ffa616be9889be348e6f2154e7f04" "ghost" "with_ghost" "9fce59fc43e5787ce68c810e409cf38f"
def empty_c51ffa61_plain : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "c51ffa616be9889be348e6f2154e7f04" "ghost" "plain" "7114bc0f7ce3e447aa9bd74d3e6d4418"
def empty_6f285044_copy2 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "6f2850447432ab97cc5d4112e433aac9" "loopcopy" "copy2" "c8a37b314145120f678fcf80ca1d6d27"
def empty_d94d326d_stale : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "d94d326dd74a1d2a765e6e3f1d21f243" "states" "stale" "c850a160887198d750551e999bf5bc83"
def empty_d94d326d_partial : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "d94d326dd74a1d2a765e6e3f1d21f243" "states" "partial" "ecd934a117e4376625071651869df4c5"
def empty_f73c96ca_add_three : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "f73c96cae96244c655c80e8fa3b71de1" "straight_line" "add_three" "dc6d724c16bea86f3f371ddf2162119b"
def empty_a3999206_scale_by_two : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "a3999206c965ceb418691a7c1bd64ea5" "workspace" "scale_by_two" "5dbfd1f078e081530352591407626e2c"
def cryptoFns_09e15c16_check_nonce : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "09e15c16a2c2be9ac5d4dc5971271ca0" "main" "check_nonce" "0a3ca2002a335ffd62b6cd22edad6146"
def parseValidateFns_ceac11a8_compute_checksum : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "compute_checksum" "c721ca16b467550acd17663a705264ba"
def parseValidateFns_ceac11a8_validate_checksum : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_checksum" "8ec0a8624d33f1d624f9c67b544221c0"
def parseValidateFns_ceac11a8_validate_msg_type : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_msg_type" "6cb688bcfaafa530ef3ef85942060cb2"
def parseValidateFns_ceac11a8_validate_payload_len : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_payload_len" "4c20bb22a0c4d96a48ef4abcc4b0dd0f"
def parseValidateFns_ceac11a8_validate_total_len : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "ceac11a87a42b223480d825dd8558e35" "parse_validate" "validate_total_len" "867ba31c93068cc4a2e4f29d41424155"
def shaFns_eda14896_big_sigma0 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "big_sigma0" "2fc56fcc1fe1179b08d9634389f4e6da"
def shaFns_eda14896_big_sigma1 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "big_sigma1" "bf9e5f67627630de3db89a6a505259bb"
def shaFns_eda14896_block_to_words_at : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "block_to_words_at" "db8c024f5788e80b30e6997a0e84f903"
def shaFns_eda14896_block_to_words : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "block_to_words" "2566f0877ae2ddb261ffb5ffe3d745ff"
def shaFns_eda14896_ch : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "ch" "3e315e17b9a1420dc0c9c4988af52511"
def shaFns_eda14896_maj : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "maj" "24c6e19e81df257bf73ad1a67b7d9d44"
def shaFns_eda14896_sha256_init : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_init" "1cbbcac2dedb20c50ca91b1953ab562f"
def shaFns_eda14896_sha256_k : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "sha256_k" "a857c18a4abd382142dd072913aa3e6f"
def shaFns_eda14896_small_sigma0 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "small_sigma0" "e153ac437b8dbdd5315d8728fde99e3b"
def shaFns_eda14896_small_sigma1 : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "eda148968d3e3a193d589bdab9f0cd97" "hmac_sha256" "small_sigma1" "ebdbe65affa2c57d59b8906600aa02f4"
def combineFns_d9933ee2_dbl : Except DefinitionIdentityRefusal DefinitionIdentity :=
  DefinitionIdentity.of? "d9933ee23eb7a3569c662bfcfb96d998" "calls" "dbl" "c3f254410bdebc8d14050f5087629bf0"

end Concrete.Proof.GeneratedAttestations
