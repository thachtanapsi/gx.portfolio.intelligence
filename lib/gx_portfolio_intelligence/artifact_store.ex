defmodule GxPortfolioIntelligence.ArtifactStore do
  @moduledoc "Safe, atomic access to orchestrator-managed artifacts."

  @max_envelope_bytes 2_000_000

  def root do
    config = Application.get_env(:gx_portfolio_intelligence, :port_runner, [])

    case Keyword.get(config, :artifact_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _ -> {:error, :artifact_root_not_configured}
    end
  end

  def path(parts) when is_list(parts) do
    with {:ok, root} <- root(),
         :ok <- validate_segments(parts),
         path = Path.join([root | parts]),
         :ok <- ensure_within(path, root) do
      {:ok, path}
    end
  end

  def write_json(parts, payload) do
    with {:ok, path} <- path(parts),
         :ok <- ensure_safe_parent(path),
         {:ok, encoded} <- Jason.encode(payload),
         :ok <- atomic_write(path, encoded <> "\n") do
      {:ok, path}
    end
  end

  def read_json(path, max_bytes \\ @max_envelope_bytes) do
    with {:ok, root} <- root(),
         expanded = Path.expand(path),
         :ok <- ensure_within(expanded, root),
         :ok <- reject_symlink_path(expanded, root),
         {:ok, stat} <- File.stat(expanded),
         true <- stat.type == :regular or {:error, :not_regular_file},
         true <- stat.size <= max_bytes or {:error, :artifact_too_large},
         {:ok, body} <- File.read(expanded),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_artifact}
    end
  end

  def ensure_within(path, root) do
    expanded = Path.expand(path)
    expanded_root = Path.expand(root)

    if expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/") do
      :ok
    else
      {:error, :path_outside_artifact_root}
    end
  end

  def ensure_port_path(path) when is_binary(path) do
    with {:ok, root} <- root(),
         expanded = Path.expand(path),
         :ok <- ensure_within(expanded, root),
         :ok <- ensure_root(root),
         :ok <- ensure_port_parent(expanded, root),
         :ok <- reject_symlink_path(expanded, root) do
      :ok
    end
  end

  def ensure_port_path(_), do: {:error, :invalid_artifact_path}

  defp validate_segments(parts) do
    if Enum.all?(
         parts,
         &(is_binary(&1) and &1 not in ["", ".", ".."] and
             not String.contains?(&1, ["/", "\\", <<0>>]))
       ) do
      :ok
    else
      {:error, :invalid_path_segment}
    end
  end

  defp ensure_safe_parent(path) do
    parent = Path.dirname(path)

    with {:ok, root} <- root(),
         :ok <- ensure_root(root),
         :ok <- reject_symlink_path(parent, root),
         :ok <- File.mkdir_p(parent),
         :ok <- reject_symlink_path(parent, root) do
      :ok
    end
  end

  defp ensure_port_parent(path, root) when path == root, do: :ok

  defp ensure_port_parent(path, root) do
    parent = Path.dirname(path)

    with :ok <- ensure_within(parent, root),
         :ok <- reject_symlink_path(parent, root),
         :ok <- File.mkdir_p(parent),
         :ok <- reject_symlink_path(parent, root) do
      :ok
    end
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, :unsafe_artifact_root}
      {:error, :enoent} -> File.mkdir_p(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_symlink_path(path, root) do
    relative = Path.relative_to(path, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_not_allowed}}
        {:ok, _} -> {:cont, next}
        {:error, :enoent} -> {:cont, next}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp atomic_write(path, body) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    case File.write(temporary, body, [:binary, :exclusive]) do
      :ok ->
        case File.rename(temporary, path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(temporary)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
