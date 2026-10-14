// Incremental UTF-8 log reader for files that Unity truncates/replaces on restart.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace InvaxionDebug
{
    public sealed class LiveLogReader
    {
        public readonly string Path;
        public bool Reopened { get; private set; }
        private long position;
        private byte[] boundary = new byte[0];
        private Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
        private string pending = "";

        public LiveLogReader(string path) { Path = path; }

        public void Reset()
        {
            position = 0;
            boundary = new byte[0];
            decoder.Reset();
            pending = "";
        }

        public string[] ReadAvailable()
        {
            Reopened = false;
            var lines = new List<string>();
            try
            {
                using (var file = new FileStream(Path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    bool changed = file.Length < position;
                    if (!changed && boundary.Length > 0)
                    {
                        file.Position = position - boundary.Length;
                        for (int i = 0; i < boundary.Length; i++)
                            if (file.ReadByte() != boundary[i]) { changed = true; break; }
                    }
                    if (changed) { Reset(); Reopened = true; }
                    file.Position = position;
                    var bytes = new byte[8192];
                    var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
                    int budget = 1024 * 1024;
                    int size;
                    while (budget > 0 && (size = file.Read(bytes, 0, Math.Min(bytes.Length, budget))) > 0)
                    {
                        budget -= size;
                        position += size;
                        int count = decoder.GetChars(bytes, 0, size, chars, 0, false);
                        pending += new string(chars, 0, count);
                        int end;
                        while ((end = pending.IndexOf('\n')) >= 0)
                        {
                            lines.Add(pending.Substring(0, end).TrimEnd('\r').TrimStart('\uFEFF'));
                            pending = pending.Substring(end + 1);
                        }
                    }
                    boundary = new byte[(int)Math.Min(64, position)];
                    file.Position = position - boundary.Length;
                    file.Read(boundary, 0, boundary.Length);
                }
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            // A writer may temporarily deny sharing while reopening its log.
            catch (IOException) { }
            return lines.ToArray();
        }

        public string Finish()
        {
            var chars = new char[8];
            int count = decoder.GetChars(new byte[0], 0, 0, chars, 0, true);
            string result = pending + new string(chars, 0, count);
            pending = "";
            return result.TrimEnd('\r').TrimStart('\uFEFF');
        }
    }
}
