ao_resolve_replica_count() {
  case "${AO_LOW_RESOURCE:-}" in
    "" | 1 | true)
      printf '1\n'
      ;;
    0 | false)
      printf '2\n'
      ;;
    *)
      echo "ERROR: AO_LOW_RESOURCE must be unset, 0, false, 1, or true" >&2
      return 1
      ;;
  esac
}
