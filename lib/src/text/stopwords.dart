/// English stopwords dropped at both index and query time.
///
/// Kept short on purpose. An aggressive list breaks real queries: `it`, `can`
/// and `no` carry meaning in technical notes, and dropping them makes titles
/// like "The Why of It" unsearchable. These are the words that appear in
/// nearly every document and so contribute nothing to ranking.
const Set<String> englishStopwords = {
  'a', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but', 'by', 'for',
  'from', 'had', 'has', 'have', 'he', 'her', 'his', 'i', 'if', 'in', 'into',
  'is', 'it', 'its', 'of', 'on', 'or', 'she', 'that', 'the', 'their', 'them',
  'then', 'there', 'these', 'they', 'this', 'to', 'was', 'were', 'which',
  'will', 'with', 'would', 'you', 'your',
};
