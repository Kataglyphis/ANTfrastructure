template <typename T>
absl::Status UntypedMessage::InsertField(const ResolverPool::Field& field,
                                         T&& value) {
  using value_type = std::decay_t<T>;
  using stored_type = std::conditional_t<
      std::is_same_v<value_type, UntypedMessage>,
      std::unique_ptr<UntypedMessage>,
      value_type>;

  auto to_stored = [&](T&& v) -> stored_type {
    if constexpr (std::is_same_v<value_type, UntypedMessage>) {
      return std::make_unique<UntypedMessage>(std::forward<T>(v));
    } else {
      return std::forward<T>(v);
    }
  };

  int32_t number = field.proto().number();
  auto it = fields_.find(number);
  if (it == fields_.end()) {
    fields_.emplace(number,
                    Value(std::in_place_type<stored_type>,
                          to_stored(std::forward<T>(value))));
    return absl::OkStatus();
  }

  if (field.proto().cardinality() !=
      google::protobuf::Field::CARDINALITY_REPEATED) {
    return absl::InvalidArgumentError(
        absl::StrCat("repeated entries for singular field number ", number));
  }

  Value& slot = it->second;
  if (auto* extant = std::get_if<stored_type>(&slot)) {
    std::vector<stored_type> repeated;
    repeated.push_back(std::move(*extant));
    repeated.push_back(to_stored(std::forward<T>(value)));
    slot.emplace<std::vector<stored_type>>(std::move(repeated));
  } else if (auto* extant = std::get_if<std::vector<stored_type>>(&slot)) {
    extant->push_back(to_stored(std::forward<T>(value)));
  } else {
    absl::optional<absl::string_view> name =
        google::protobuf::internal::RttiTypeName<stored_type>();
    if (!name.has_value()) {
      name = "<unknown>";
    }

    return absl::InvalidArgumentError(
        absl::StrFormat("inconsistent types for field number %d: tried to "
                        "insert '%s', but index was %d",
                        number, *name, slot.index()));
  }

  return absl::OkStatus();
}
