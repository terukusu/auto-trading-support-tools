// 2) CSVから２次元配列に変換
function csv2Array(str) {
  var csvData = [];
  var lines = str.split("\n");
  for (var i = 0; i < lines.length; ++i) {
    var cells = lines[i].split(",");
    csvData.push(cells);
  }
  return csvData;
}

function drawChart(data) {
  // 3)chart.jsのdataset用の配列を用意
  var tmpLabels = [], tmpData1 = [], tmpData2 = [], tmpData3 = [], tmpData4 = [];
  for (var row in data) {
    tmpLabels.push(data[row][0])
    tmpData1.push(data[row][1])
    tmpData2.push(data[row][2])
    tmpData3.push(data[row][3])
    tmpData4.push(data[row][4])
  };

  // 4)chart.jsで描画
  var ctx = document.getElementById("chartCanvas").getContext("2d");
  var myChart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: tmpLabels,
      datasets: [
        { label: "EUR/USD(FATE-II-1K)", data: tmpData2, borderColor: "blue",
          backgroundColor: "blue", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0},
        { label: "EUR/USD(FATE-II-10K)", data: tmpData3, borderColor: "green",
          backgroundColor: "green", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0},
        { label: "EUR/USD(FATE-II-1M)", data: tmpData1, borderColor: "red",
          backgroundColor: "red", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0},
        { label: "EUR/USD(AveragingMaster)", data: tmpData4, borderColor: "purple",
          backgroundColor: "purple", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0},
      ]
    }
  });
}

function main() {
  // 1) ajaxでCSVファイルをロード
  var req = new XMLHttpRequest();
  var filePath = '../cgi-bin/spread.cgi';
  req.open("GET", filePath, true);
  req.onload = function() {
    // 2) CSVデータ変換の呼び出し
    data = csv2Array(req.responseText);
    // 3) chart.jsデータ準備、4) chart.js描画の呼び出し
    drawChart(data);
  }
  req.send(null);
}

main();
