defmodule Data.Filters.Notifications do
  @moduledoc """
  The bell's `$where` (`GET /notifications` in the console, the portal and
  the extension; AQ-11B §3 #10). The person's own notifications are the
  base query's; `cursor` and `limit` stay parameters.

  | Field | Operators | Is |
  |---|---|---|
  | `unread` | `$EQUAL` | `true`: not read yet; `false`: no filter |
  | `group` | `$EQUAL` `$IN` | the kind's group (`notification_groups`' keys, e.g. `tasks`) |
  """

  use FatEcto.Query.Dynamics.Buildable,
    overrideable: ["unread", "group"],
    ignoreable: [unread: ["", nil], group: ["", nil, []]]

  use Data.Filters, operators: [unread: ["$EQUAL"], group: ["$EQUAL", "$IN"]]

  import Ecto.Query

  alias Data.Notifications.Kind

  @impl Data.Filters
  def prepare("unread", "$EQUAL", value, _context), do: Data.Filters.boolean(value)

  def prepare("group", _op, value, _context) do
    groups = Enum.map(Data.Filters.listed(value), &to_string/1)
    if groups != [] and Enum.all?(groups, &(&1 =~ ~r/^[a-z_]+$/)), do: {:ok, groups}, else: :error
  end

  def prepare(_field, _op, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("unread", "$EQUAL", true), do: dynamic([n], is_nil(n.read_at))

  def override_buildable("group", _op, groups) when is_list(groups) do
    kinds = from(k in Kind, where: k.notification_group_key in ^groups, select: k.key)
    dynamic([n], n.notification_kind_key in subquery(kinds))
  end

  def override_buildable(_field, _operator, _value), do: nil
end
