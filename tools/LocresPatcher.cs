// LANG_ES_FIX FIX - lector/parcheador LOCRES autocontenido.
// Formato basado en TextLocalizationResource de Unreal Engine y en la
// documentacion publica de LocresLib (MIT, akintos/UnrealLocres).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace LangEsFix
{
    public sealed class PatchStats
    {
        public int OriginalEntries { get; set; }
        public int FinalEntries { get; set; }
        public int Requested { get; set; }
        public int Changed { get; set; }
        public int AlreadyCorrect { get; set; }
        public int Added { get; set; }
        public int EnglishMatches { get; set; }
        public int EnglishMismatches { get; set; }
        public int EnglishMissing { get; set; }
        public int Verified { get; set; }
        public int UnrelatedVerified { get; set; }
    }

    internal sealed class Correction
    {
        public string FullKey;
        public string Namespace;
        public string Key;
        public uint SourceHash;
        public string Source;
        public string Translation;
        public string Category;
    }

    internal sealed class LocresEntry
    {
        public string Key;
        public uint SourceHash;
        public string Value;
    }

    internal sealed class LocresNamespace
    {
        public string Name;
        public readonly List<LocresEntry> Entries = new List<LocresEntry>();
    }

    internal sealed class LocresDocument
    {
        private static readonly byte[] Magic = new byte[] {
            0x0E, 0x14, 0x74, 0x75, 0x67, 0x4A, 0x03, 0xFC,
            0x4A, 0x15, 0x90, 0x9D, 0xC3, 0x37, 0x7F, 0x1B
        };

        public readonly List<LocresNamespace> Namespaces = new List<LocresNamespace>();

        public int Count
        {
            get { return Namespaces.Sum(x => x.Entries.Count); }
        }

        public Dictionary<string, LocresEntry> CreateIndex()
        {
            Dictionary<string, LocresEntry> result = new Dictionary<string, LocresEntry>(StringComparer.Ordinal);
            foreach (LocresNamespace ns in Namespaces)
            {
                foreach (LocresEntry entry in ns.Entries)
                {
                    result[ns.Name + "/" + entry.Key] = entry;
                }
            }
            return result;
        }

        public LocresNamespace GetOrAddNamespace(string name)
        {
            LocresNamespace existing = Namespaces.FirstOrDefault(x => String.Equals(x.Name, name, StringComparison.Ordinal));
            if (existing != null) return existing;
            LocresNamespace created = new LocresNamespace();
            created.Name = name;
            Namespaces.Add(created);
            return created;
        }

        public static LocresDocument Load(string path)
        {
            using (FileStream stream = File.OpenRead(path))
            using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8))
            {
                byte[] first = reader.ReadBytes(16);
                byte version;
                if (first.SequenceEqual(Magic))
                {
                    version = reader.ReadByte();
                }
                else
                {
                    version = 0;
                    stream.Position = 0;
                }

                if (version > 3) throw new InvalidDataException("Version LOCRES no soportada: " + version);

                string[] localizedStrings = null;
                if (version >= 1)
                {
                    long tableOffset = reader.ReadInt64();
                    long returnPosition = stream.Position;
                    if (tableOffset < 0 || tableOffset >= stream.Length) throw new InvalidDataException("Offset de tabla LOCRES invalido.");
                    stream.Position = tableOffset;
                    int stringCount = reader.ReadInt32();
                    if (stringCount < 0 || stringCount > 10000000) throw new InvalidDataException("Cantidad de cadenas LOCRES invalida.");
                    localizedStrings = new string[stringCount];
                    for (int i = 0; i < stringCount; i++)
                    {
                        localizedStrings[i] = ReadUnrealString(reader);
                        if (version >= 2) reader.ReadInt32();
                    }
                    stream.Position = returnPosition;
                }

                if (version >= 2) reader.ReadInt32();
                int namespaceCount = reader.ReadInt32();
                if (namespaceCount < 0 || namespaceCount > 1000000) throw new InvalidDataException("Cantidad de namespaces LOCRES invalida.");

                LocresDocument doc = new LocresDocument();
                for (int n = 0; n < namespaceCount; n++)
                {
                    if (version >= 2) reader.ReadUInt32();
                    LocresNamespace ns = new LocresNamespace();
                    ns.Name = ReadUnrealString(reader);
                    int entryCount = reader.ReadInt32();
                    if (entryCount < 0 || entryCount > 10000000) throw new InvalidDataException("Cantidad de entradas LOCRES invalida.");
                    for (int e = 0; e < entryCount; e++)
                    {
                        if (version >= 2) reader.ReadUInt32();
                        LocresEntry entry = new LocresEntry();
                        entry.Key = ReadUnrealString(reader);
                        entry.SourceHash = reader.ReadUInt32();
                        if (version >= 1)
                        {
                            int stringIndex = reader.ReadInt32();
                            if (stringIndex < 0 || stringIndex >= localizedStrings.Length) throw new InvalidDataException("Indice de cadena LOCRES invalido.");
                            entry.Value = localizedStrings[stringIndex];
                        }
                        else
                        {
                            entry.Value = ReadUnrealString(reader);
                        }
                        ns.Entries.Add(entry);
                    }
                    doc.Namespaces.Add(ns);
                }
                return doc;
            }
        }

        public void SaveOptimized(string path)
        {
            string parent = Path.GetDirectoryName(path);
            if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            using (FileStream stream = File.Create(path))
            using (BinaryWriter writer = new BinaryWriter(stream, Encoding.UTF8))
            {
                writer.Write(Magic);
                writer.Write((byte)2);
                long tableOffsetPosition = stream.Position;
                writer.Write((long)0);
                long totalCountPosition = stream.Position;
                writer.Write(0);
                writer.Write(Namespaces.Count);

                List<string> stringTable = new List<string>();
                Dictionary<string, int> stringIndexes = new Dictionary<string, int>(StringComparer.Ordinal);
                Dictionary<string, int> stringReferences = new Dictionary<string, int>(StringComparer.Ordinal);
                int totalEntries = 0;

                foreach (LocresNamespace ns in Namespaces)
                {
                    writer.Write(StrCrc32(ns.Name));
                    WriteUnrealString(writer, ns.Name);
                    writer.Write(ns.Entries.Count);
                    foreach (LocresEntry entry in ns.Entries)
                    {
                        writer.Write(StrCrc32(entry.Key));
                        WriteUnrealString(writer, entry.Key);
                        writer.Write(entry.SourceHash);
                        int index;
                        if (!stringIndexes.TryGetValue(entry.Value, out index))
                        {
                            index = stringTable.Count;
                            stringTable.Add(entry.Value);
                            stringIndexes[entry.Value] = index;
                            stringReferences[entry.Value] = 1;
                        }
                        else
                        {
                            stringReferences[entry.Value] = stringReferences[entry.Value] + 1;
                        }
                        writer.Write(index);
                        totalEntries++;
                    }
                }

                long tableOffset = stream.Position;
                writer.Write(stringTable.Count);
                foreach (string value in stringTable)
                {
                    WriteUnrealString(writer, value);
                    writer.Write(stringReferences[value]);
                }

                long end = stream.Position;
                stream.Position = tableOffsetPosition;
                writer.Write(tableOffset);
                stream.Position = totalCountPosition;
                writer.Write(totalEntries);
                stream.Position = end;
            }
        }

        private static string ReadUnrealString(BinaryReader reader)
        {
            int length = reader.ReadInt32();
            if (length == 0) return String.Empty;
            if (length > 0)
            {
                byte[] bytes = reader.ReadBytes(length);
                if (bytes.Length != length) throw new EndOfStreamException();
                return Encoding.ASCII.GetString(bytes).TrimEnd('\0');
            }
            int byteCount = checked(-length * 2);
            byte[] unicode = reader.ReadBytes(byteCount);
            if (unicode.Length != byteCount) throw new EndOfStreamException();
            return Encoding.Unicode.GetString(unicode).TrimEnd('\0');
        }

        private static void WriteUnrealString(BinaryWriter writer, string value)
        {
            if (value == null) value = String.Empty;
            bool ascii = value.All(c => c <= 127);
            if (ascii)
            {
                byte[] bytes = Encoding.ASCII.GetBytes(value + "\0");
                writer.Write(bytes.Length);
                writer.Write(bytes);
            }
            else
            {
                string terminated = value + "\0";
                byte[] bytes = Encoding.Unicode.GetBytes(terminated);
                writer.Write(-terminated.Length);
                writer.Write(bytes);
            }
        }

        private static uint StrCrc32(string value)
        {
            uint crc = 0xFFFFFFFFu;
            foreach (char input in value)
            {
                uint ch = input;
                for (int part = 0; part < 4; part++)
                {
                    byte current = (byte)(ch & 0xFF);
                    crc ^= current;
                    for (int bit = 0; bit < 8; bit++)
                        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320u : 0u);
                    ch >>= 8;
                }
            }
            return ~crc;
        }
    }

    public static class LocresPatcher
    {
        public static PatchStats PatchFromCsv(string spanishLocres, string englishLocres, string correctionsCsv,
            string outputLocres, string reportCsv, bool addMissing)
        {
            Dictionary<string, Correction> corrections = LoadCorrections(correctionsCsv);
            LocresDocument spanish = LocresDocument.Load(spanishLocres);
            LocresDocument english = String.IsNullOrEmpty(englishLocres) ? null : LocresDocument.Load(englishLocres);
            Dictionary<string, LocresEntry> spanishIndex = spanish.CreateIndex();
            Dictionary<string, string> originalValues = spanishIndex.ToDictionary(x => x.Key, x => x.Value.Value, StringComparer.Ordinal);
            Dictionary<string, uint> originalSourceHashes = spanishIndex.ToDictionary(x => x.Key, x => x.Value.SourceHash, StringComparer.Ordinal);
            Dictionary<string, LocresEntry> englishIndex = english == null ? null : english.CreateIndex();
            PatchStats stats = new PatchStats();
            stats.OriginalEntries = spanish.Count;
            stats.Requested = corrections.Count;

            List<string[]> report = new List<string[]>();
            foreach (Correction correction in corrections.Values.OrderBy(x => x.Source, StringComparer.OrdinalIgnoreCase))
            {
                string englishStatus = "not_checked";
                if (englishIndex != null)
                {
                    LocresEntry en;
                    if (!englishIndex.TryGetValue(correction.FullKey, out en))
                    {
                        englishStatus = "missing";
                        stats.EnglishMissing++;
                    }
                    else if (String.Equals(en.Value, correction.Source, StringComparison.Ordinal))
                    {
                        englishStatus = "match";
                        stats.EnglishMatches++;
                    }
                    else
                    {
                        englishStatus = "different:" + en.Value;
                        stats.EnglishMismatches++;
                    }
                }

                LocresEntry existing;
                string before = String.Empty;
                string action;
                if (spanishIndex.TryGetValue(correction.FullKey, out existing))
                {
                    before = existing.Value;
                    if (String.Equals(existing.Value, correction.Translation, StringComparison.Ordinal))
                    {
                        action = "already_correct";
                        stats.AlreadyCorrect++;
                    }
                    else
                    {
                        existing.Value = correction.Translation;
                        action = "changed";
                        stats.Changed++;
                    }
                }
                else if (addMissing)
                {
                    LocresNamespace ns = spanish.GetOrAddNamespace(correction.Namespace);
                    existing = new LocresEntry();
                    existing.Key = correction.Key;
                    existing.SourceHash = correction.SourceHash;
                    existing.Value = correction.Translation;
                    ns.Entries.Add(existing);
                    spanishIndex[correction.FullKey] = existing;
                    action = "added_for_mod_or_variant";
                    stats.Added++;
                }
                else
                {
                    action = "missing";
                }

                report.Add(new string[] {
                    correction.FullKey, correction.Source, before, correction.Translation,
                    correction.Category, action, englishStatus, correction.SourceHash.ToString(CultureInfo.InvariantCulture)
                });
            }

            spanish.SaveOptimized(outputLocres);
            LocresDocument verified = LocresDocument.Load(outputLocres);
            Dictionary<string, LocresEntry> verifiedIndex = verified.CreateIndex();
            foreach (KeyValuePair<string, string> original in originalValues)
            {
                LocresEntry finalEntry;
                if (!verifiedIndex.TryGetValue(original.Key, out finalEntry))
                    throw new InvalidDataException("La clave original desaparecio: " + original.Key);
                if (finalEntry.SourceHash != originalSourceHashes[original.Key])
                    throw new InvalidDataException("Cambio inesperado de source hash: " + original.Key);
                if (!corrections.ContainsKey(original.Key))
                {
                    if (!String.Equals(finalEntry.Value, original.Value, StringComparison.Ordinal))
                        throw new InvalidDataException("Cambio fuera del CSV: " + original.Key);
                    stats.UnrelatedVerified++;
                }
            }
            foreach (string finalKey in verifiedIndex.Keys)
            {
                if (!originalValues.ContainsKey(finalKey) && !corrections.ContainsKey(finalKey))
                    throw new InvalidDataException("Clave agregada fuera del CSV: " + finalKey);
            }
            foreach (Correction correction in corrections.Values)
            {
                LocresEntry entry;
                if (verifiedIndex.TryGetValue(correction.FullKey, out entry) &&
                    String.Equals(entry.Value, correction.Translation, StringComparison.Ordinal)) stats.Verified++;
            }
            stats.FinalEntries = verified.Count;
            if (stats.Verified != stats.Requested)
                throw new InvalidDataException("Verificacion LOCRES incompleta: " + stats.Verified + "/" + stats.Requested);
            if (stats.FinalEntries != stats.OriginalEntries + stats.Added)
                throw new InvalidDataException("El numero final de entradas LOCRES no coincide con lo esperado.");

            WriteReport(reportCsv, report);
            return stats;
        }

        public static int CountEntries(string path)
        {
            return LocresDocument.Load(path).Count;
        }

        private static Dictionary<string, Correction> LoadCorrections(string path)
        {
            string[] lines = File.ReadAllLines(path, Encoding.UTF8);
            if (lines.Length < 2) throw new InvalidDataException("CSV de correcciones vacio.");
            List<string> headers = ParseCsvLine(lines[0]);
            Dictionary<string, int> columns = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headers.Count; i++) columns[headers[i].Trim().Trim('\uFEFF')] = i;
            string[] required = new string[] { "enabled", "namespace", "key", "source_hash", "source", "translation", "category" };
            foreach (string name in required)
                if (!columns.ContainsKey(name)) throw new InvalidDataException("Falta columna CSV: " + name);

            Dictionary<string, Correction> result = new Dictionary<string, Correction>(StringComparer.Ordinal);
            for (int lineNumber = 1; lineNumber < lines.Length; lineNumber++)
            {
                if (String.IsNullOrWhiteSpace(lines[lineNumber])) continue;
                List<string> values = ParseCsvLine(lines[lineNumber]);
                Func<string, string> get = delegate(string name) {
                    int index = columns[name];
                    return index < values.Count ? values[index] : String.Empty;
                };
                if (get("enabled") != "1") continue;
                Correction correction = new Correction();
                correction.Namespace = get("namespace");
                correction.Key = get("key");
                correction.Source = get("source");
                correction.Translation = get("translation");
                correction.Category = get("category");
                uint parsed;
                if (!UInt32.TryParse(get("source_hash"), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                    throw new InvalidDataException("source_hash invalido en linea " + (lineNumber + 1));
                correction.SourceHash = parsed;
                if (String.IsNullOrWhiteSpace(correction.Namespace) || String.IsNullOrWhiteSpace(correction.Key) || String.IsNullOrWhiteSpace(correction.Translation))
                    throw new InvalidDataException("Correccion incompleta en linea " + (lineNumber + 1));
                correction.FullKey = correction.Namespace + "/" + correction.Key;
                Correction duplicate;
                if (result.TryGetValue(correction.FullKey, out duplicate) &&
                    !String.Equals(duplicate.Translation, correction.Translation, StringComparison.Ordinal))
                    throw new InvalidDataException("Conflicto para clave " + correction.FullKey);
                result[correction.FullKey] = correction;
            }
            return result;
        }

        private static List<string> ParseCsvLine(string line)
        {
            List<string> result = new List<string>();
            StringBuilder field = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < line.Length; i++)
            {
                char ch = line[i];
                if (quoted)
                {
                    if (ch == '"')
                    {
                        if (i + 1 < line.Length && line[i + 1] == '"') { field.Append('"'); i++; }
                        else quoted = false;
                    }
                    else field.Append(ch);
                }
                else
                {
                    if (ch == '"') quoted = true;
                    else if (ch == ',') { result.Add(field.ToString()); field.Length = 0; }
                    else field.Append(ch);
                }
            }
            if (quoted) throw new InvalidDataException("Comillas CSV sin cerrar.");
            result.Add(field.ToString());
            return result;
        }

        private static string Csv(string value)
        {
            if (value == null) value = String.Empty;
            return "\"" + value.Replace("\"", "\"\"") + "\"";
        }

        private static void WriteReport(string path, List<string[]> rows)
        {
            string parent = Path.GetDirectoryName(path);
            if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            using (StreamWriter writer = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                writer.WriteLine("\"key\",\"source_english\",\"spanish_before\",\"target\",\"category\",\"action\",\"english_status\",\"source_hash\"");
                foreach (string[] row in rows) writer.WriteLine(String.Join(",", row.Select(Csv).ToArray()));
            }
        }
    }
}
